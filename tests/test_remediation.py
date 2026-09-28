from unittest.mock import MagicMock

import boto3
import pytest
from conftest import load_module
from moto import mock_aws

PARAM = "/obs-app/test/last-known-good-version"


def alarm_event(state="ALARM"):
    return {
        "source": "aws.cloudwatch",
        "detail-type": "CloudWatch Alarm State Change",
        "detail": {"alarmName": "obs-app-test-5xx-rate", "state": {"value": state}},
    }


@pytest.fixture
def remediation(monkeypatch):
    with mock_aws():
        topic = boto3.client("sns").create_topic(Name="obs-app-test-alerts")["TopicArn"]
        boto3.client("ssm").put_parameter(Name=PARAM, Value="3", Type="String")
        monkeypatch.setenv("TARGET_FUNCTION_NAME", "obs-app-test-api")
        monkeypatch.setenv("TARGET_ALIAS_NAME", "live")
        monkeypatch.setenv("LAST_KNOWN_GOOD_PARAM", PARAM)
        monkeypatch.setenv("ALERT_TOPIC_ARN", topic)
        mod = load_module("handler", "src/remediation")
        mod.lambda_client = MagicMock()
        mod.sns = MagicMock()
        yield mod


def test_rolls_back_to_last_known_good(remediation, context):
    remediation.lambda_client.get_alias.return_value = {"FunctionVersion": "5"}

    result = remediation.handler(alarm_event(), context)

    assert result["action"] == "rollback"
    remediation.lambda_client.update_alias.assert_called_once()
    assert remediation.lambda_client.update_alias.call_args.kwargs["FunctionVersion"] == "3"
    remediation.sns.publish.assert_called_once()


def test_noop_when_already_on_good_version(remediation, context):
    remediation.lambda_client.get_alias.return_value = {"FunctionVersion": "3"}

    result = remediation.handler(alarm_event(), context)

    assert result["action"] == "noop"
    remediation.lambda_client.update_alias.assert_not_called()


def test_repeated_alarm_rolls_back_once(remediation, context):
    versions = iter(["5", "3"])
    remediation.lambda_client.get_alias.side_effect = lambda **_: {"FunctionVersion": next(versions)}

    first = remediation.handler(alarm_event(), context)
    second = remediation.handler(alarm_event(), context)

    assert (first["action"], second["action"]) == ("rollback", "noop")
    assert remediation.lambda_client.update_alias.call_count == 1


def test_ignores_ok_state(remediation, context):
    result = remediation.handler(alarm_event("OK"), context)

    assert result["action"] == "ignored"
    remediation.lambda_client.get_alias.assert_not_called()
