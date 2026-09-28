"""자동 복구 Lambda — 5xx 비율 알람이 ALARM이 되면 live 별칭을 last-known-good 버전으로 되돌린다.

EventBridge 'CloudWatch Alarm State Change' 이벤트로 호출된다.
현재 버전이 이미 목표 버전이면 아무것도 하지 않는다 (멱등).
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger

logger = Logger()

lambda_client = boto3.client("lambda")
ssm = boto3.client("ssm")
sns = boto3.client("sns")

FUNCTION_NAME = os.environ["TARGET_FUNCTION_NAME"]
ALIAS_NAME = os.environ["TARGET_ALIAS_NAME"]
PARAM_NAME = os.environ["LAST_KNOWN_GOOD_PARAM"]
TOPIC_ARN = os.environ["ALERT_TOPIC_ARN"]


def notify(subject: str, detail: dict) -> None:
    sns.publish(TopicArn=TOPIC_ARN, Subject=subject[:100], Message=json.dumps(detail, indent=2, ensure_ascii=False))


@logger.inject_lambda_context
def handler(event, context):
    detail = event.get("detail", {})
    alarm_name = detail.get("alarmName", "unknown")
    state = detail.get("state", {}).get("value")

    if state != "ALARM":
        logger.info("Ignoring non-ALARM state", extra={"alarm": alarm_name, "state": state})
        return {"action": "ignored", "reason": f"state={state}"}

    target = ssm.get_parameter(Name=PARAM_NAME)["Parameter"]["Value"]
    current = lambda_client.get_alias(FunctionName=FUNCTION_NAME, Name=ALIAS_NAME)["FunctionVersion"]
    result = {"alarm": alarm_name, "function": FUNCTION_NAME, "alias": ALIAS_NAME, "from": current, "to": target}

    if current == target:
        # 이미 정상 버전인데도 알람 → 코드 결함이 아닌 다른 원인. 사람이 판단해야 함
        logger.warning("Alias already at last-known-good; no rollback", extra=result)
        notify(f"[obs-app] 롤백 불필요 — {alarm_name}", {**result, "action": "noop"})
        return {**result, "action": "noop"}

    lambda_client.update_alias(
        FunctionName=FUNCTION_NAME,
        Name=ALIAS_NAME,
        FunctionVersion=target,
        Description=f"auto-rollback by {alarm_name}",
    )
    logger.info("Rolled back alias", extra=result)
    notify(f"[obs-app] 자동 롤백 완료 v{current} → v{target}", {**result, "action": "rollback"})
    return {**result, "action": "rollback"}
