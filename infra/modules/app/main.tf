# 비즈니스 Lambda + live 별칭 + DynamoDB + last-known-good 파라미터
#
# 소유권 분리:
#   - 함수 코드, live 별칭 버전, last-known-good 값은 CI(deploy.yml)와 복구 Lambda가 관리한다.
#   - Terraform은 최초 생성만 하고 이후 변경은 ignore_changes로 무시한다.

locals {
  function_name = "${var.name_prefix}-api"
}

# ---------------------------------------------------------------------------
# DynamoDB
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "items" {
  name         = "${var.name_prefix}-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "assume_lambda" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "api" {
  name               = "${local.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

data "aws_iam_policy_document" "api" {
  statement {
    sid       = "Items"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.items.arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.api.arn}:*"]
  }
}

resource "aws_iam_role_policy" "api" {
  name   = "app"
  role   = aws_iam_role.api.id
  policy = data.aws_iam_policy_document.api.json
}

# X-Ray 전송은 리소스 단위 권한을 지원하지 않아 AWS 관리형 정책 사용
resource "aws_iam_role_policy_attachment" "api_xray" {
  role       = aws_iam_role.api.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

data "archive_file" "api" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/.build/${local.function_name}.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "api" {
  function_name = local.function_name
  role          = aws_iam_role.api.arn
  runtime       = "python3.12"
  architectures = ["arm64"]
  handler       = "app.handler"
  memory_size   = 256
  timeout       = 10
  publish       = true
  layers        = [var.powertools_layer_arn]

  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256

  environment {
    variables = {
      TABLE_NAME                   = aws_dynamodb_table.items.name
      FAULT_RATE                   = "0"
      POWERTOOLS_SERVICE_NAME      = local.function_name
      POWERTOOLS_METRICS_NAMESPACE = var.metrics_namespace
      POWERTOOLS_LOG_LEVEL         = "INFO"
    }
  }

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.api, aws_iam_role_policy.api]

  lifecycle {
    # 코드 배포는 CI 소유 — Terraform은 최초 생성 시에만 코드를 올린다
    ignore_changes = [filename, source_code_hash]
  }
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.api.function_name
  function_version = aws_lambda_function.api.version

  lifecycle {
    # 별칭이 가리키는 버전은 CI와 복구 Lambda 소유 — apply가 롤백을 되돌리지 않도록 무시
    ignore_changes = [function_version, description]
  }
}

resource "aws_ssm_parameter" "last_known_good" {
  name        = "/${var.project}/${var.environment}/last-known-good-version"
  description = "Last Lambda version that passed the smoke test (auto-rollback target)"
  type        = "String"
  value       = aws_lambda_function.api.version

  lifecycle {
    ignore_changes = [value]
  }
}
