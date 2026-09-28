import json

import boto3
import pytest
from conftest import load_module
from moto import mock_aws

TABLE = "obs-app-test-items"


def http_event(method, path, body=None):
    return {
        "version": "2.0",
        "routeKey": f"{method} {path}",
        "rawPath": path,
        "rawQueryString": "",
        "headers": {"content-type": "application/json"},
        "requestContext": {
            "http": {"method": method, "path": path, "sourceIp": "127.0.0.1"},
            "requestId": "req-123",
            "stage": "$default",
        },
        "body": body,
        "isBase64Encoded": False,
    }


@pytest.fixture
def app(monkeypatch):
    monkeypatch.setenv("TABLE_NAME", TABLE)
    monkeypatch.setenv("FAULT_RATE", "0")
    with mock_aws():
        boto3.client("dynamodb").create_table(
            TableName=TABLE,
            KeySchema=[{"AttributeName": "id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        yield load_module("app", "src/app")


def call(app, context, method, path, body=None):
    res = app.handler(http_event(method, path, body), context)
    return res["statusCode"], json.loads(res["body"]), res["headers"]


def test_health(app, context):
    status, body, headers = call(app, context, "GET", "/health")
    assert status == 200
    assert body["status"] == "ok"
    assert headers["x-request-id"] == "req-123"


def test_create_then_get(app, context):
    payload = {"name": "a", "qty": 3, "price": 1.5}
    status, created, _ = call(app, context, "POST", "/items", json.dumps({"payload": payload}))
    assert status == 201

    status, item, _ = call(app, context, "GET", f"/items/{created['id']}")
    assert status == 200
    assert item["payload"] == payload
    assert item["status"] == "active"


def test_get_missing_returns_404(app, context):
    status, body, _ = call(app, context, "GET", "/items/nope")
    assert status == 404
    assert body["error"]["code"] == "NOT_FOUND"
    assert body["error"]["requestId"] == "req-123"


@pytest.mark.parametrize(
    "body, code",
    [
        ("not json", "INVALID_JSON"),
        (json.dumps({"payload": "str"}), "INVALID_PAYLOAD"),
        (json.dumps([1, 2]), "INVALID_PAYLOAD"),
        (json.dumps({"payload": {"x": "a" * 11000}}), "PAYLOAD_TOO_LARGE"),
    ],
)
def test_create_rejects_bad_input(app, context, body, code):
    status, res, _ = call(app, context, "POST", "/items", body)
    assert status == 400
    assert res["error"]["code"] == code


def test_fault_injection_raises(app, context, monkeypatch):
    monkeypatch.setattr(app, "FAULT_RATE", 1.0)
    with pytest.raises(RuntimeError, match="Injected fault"):
        app.handler(http_event("GET", "/items/x"), context)
    # health는 장애 주입 대상이 아님
    assert app.handler(http_event("GET", "/health"), context)["statusCode"] == 200
