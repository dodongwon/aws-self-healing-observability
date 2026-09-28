"""비즈니스 API Lambda — GET /health, POST /items, GET /items/{id}"""

import json
import os
import random
import uuid
from datetime import UTC, datetime
from decimal import Decimal

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.event_handler import APIGatewayHttpResolver, Response, content_types
from aws_lambda_powertools.logging import correlation_paths
from aws_lambda_powertools.metrics import MetricUnit

MAX_PAYLOAD_BYTES = 10 * 1024

logger = Logger()
tracer = Tracer()
metrics = Metrics()


def _json_default(obj):
    # DynamoDB는 숫자를 Decimal로 돌려준다 → JSON 숫자로 복원
    if isinstance(obj, Decimal):
        return int(obj) if obj == obj.to_integral_value() else float(obj)
    raise TypeError(f"Unserializable type: {type(obj).__name__}")


app = APIGatewayHttpResolver(serializer=lambda obj: json.dumps(obj, default=_json_default))

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])

# 장애 주입 비율 — 환경변수는 게시된 Lambda 버전에 고정되므로 롤백하면 함께 사라진다
FAULT_RATE = float(os.environ.get("FAULT_RATE", "0"))


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@app.exception_handler(ApiError)
def handle_api_error(err: ApiError) -> Response:
    request_id = app.current_event.request_context.request_id
    return Response(
        status_code=err.status,
        content_type=content_types.APPLICATION_JSON,
        body=json.dumps({"error": {"code": err.code, "message": err.message, "requestId": request_id}}),
    )


def inject_fault() -> None:
    if FAULT_RATE > 0 and random.random() < FAULT_RATE:
        logger.warning("Injected fault", extra={"fault_rate": FAULT_RATE})
        raise RuntimeError("Injected fault")


@app.get("/health")
def health():
    return {"status": "ok", "version": os.environ.get("AWS_LAMBDA_FUNCTION_VERSION", "local")}


@app.post("/items")
@tracer.capture_method
def create_item():
    inject_fault()

    raw = app.current_event.body or ""
    if len(raw.encode()) > MAX_PAYLOAD_BYTES:
        raise ApiError(400, "PAYLOAD_TOO_LARGE", f"Body must be {MAX_PAYLOAD_BYTES} bytes or less")
    try:
        body = json.loads(raw, parse_float=Decimal)  # DynamoDB는 float를 허용하지 않음
    except json.JSONDecodeError:
        raise ApiError(400, "INVALID_JSON", "Body must be valid JSON")
    if not isinstance(body, dict) or not isinstance(body.get("payload"), dict):
        raise ApiError(400, "INVALID_PAYLOAD", "Body must be an object with a 'payload' object")

    item = {
        "id": str(uuid.uuid4()),
        "createdAt": datetime.now(UTC).isoformat(),
        "status": "active",
        "payload": body["payload"],
    }
    table.put_item(Item=item)
    metrics.add_metric(name="ItemsCreated", unit=MetricUnit.Count, value=1)
    logger.info("Item created", extra={"item_id": item["id"]})
    return Response(
        status_code=201,
        content_type=content_types.APPLICATION_JSON,
        body=json.dumps({"id": item["id"], "createdAt": item["createdAt"]}),
    )


@app.get("/items/<item_id>")
@tracer.capture_method
def get_item(item_id: str):
    inject_fault()

    item = table.get_item(Key={"id": item_id}).get("Item")
    if item is None:
        raise ApiError(404, "NOT_FOUND", f"Item '{item_id}' not found")
    return item


@logger.inject_lambda_context(correlation_id_path=correlation_paths.API_GATEWAY_HTTP)
@tracer.capture_lambda_handler
@metrics.log_metrics
def handler(event, context):
    response = app.resolve(event, context)
    response.setdefault("headers", {})["x-request-id"] = app.current_event.request_context.request_id
    return response
