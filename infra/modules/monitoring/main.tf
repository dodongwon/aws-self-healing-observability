# 알람 3종 + 대시보드 + 자가복구(EventBridge → 복구 Lambda)
#
# 알람 설계 원칙: 자동조치 알람은 보수적으로, 알림 전용 알람은 민감하게
#   ① 5xx-rate    : 5분 합계 요청 ≥ 10 이고 5xx 비율 > 5%, 2회 연속 → 자동 롤백 + 이메일
#   ② 5xx-count   : 5분 합계 5xx ≥ 3                              → 이메일
#   ③ p99-latency : p99 > 3초, 3회 중 2회                          → 이메일
# 모든 알람이 SNS로 직접 통보하므로 복구 Lambda가 실패해도 장애 통보는 보장된다.

locals {
  remediation_name = "${var.name_prefix}-remediation"
  api_dimensions   = { ApiId = var.api_id }
}

# ---------------------------------------------------------------------------
# 알람
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "error_rate" {
  alarm_name          = "${var.name_prefix}-5xx-rate"
  alarm_description   = "5xx rate > 5% (min 10 req / 5 min) for 2 periods - triggers auto-rollback"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 5
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alert_topic_arn]
  ok_actions          = [var.alert_topic_arn]

  metric_query {
    id          = "rate"
    expression  = "IF(requests >= 10, 100 * FILL(errors, 0) / requests, 0)"
    label       = "5xx rate (%)"
    return_data = true
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "Count"
      dimensions  = local.api_dimensions
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApiGateway"
      metric_name = "5xx"
      dimensions  = local.api_dimensions
      period      = 300
      stat        = "Sum"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "error_count" {
  alarm_name          = "${var.name_prefix}-5xx-count"
  alarm_description   = "3+ 5xx in 5 min regardless of traffic - notify only"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = local.api_dimensions
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alert_topic_arn]
  ok_actions          = [var.alert_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "latency" {
  alarm_name          = "${var.name_prefix}-p99-latency"
  alarm_description   = "p99 latency > 3s in 2 of 3 periods - notify only"
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = local.api_dimensions
  extended_statistic  = "p99"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 3000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alert_topic_arn]
  ok_actions          = [var.alert_topic_arn]
}

# ---------------------------------------------------------------------------
# 복구 Lambda
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

resource "aws_iam_role" "remediation" {
  name               = "${local.remediation_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume_lambda.json
}

data "aws_iam_policy_document" "remediation" {
  statement {
    sid       = "RollbackAlias"
    actions   = ["lambda:GetAlias", "lambda:UpdateAlias"]
    resources = [var.target_function_arn, "${var.target_function_arn}:*"]
  }

  statement {
    sid       = "ReadLastKnownGood"
    actions   = ["ssm:GetParameter"]
    resources = [var.last_known_good_param_arn]
  }

  statement {
    sid       = "Notify"
    actions   = ["sns:Publish"]
    resources = [var.alert_topic_arn]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.remediation.arn}:*"]
  }
}

resource "aws_iam_role_policy" "remediation" {
  name   = "remediation"
  role   = aws_iam_role.remediation.id
  policy = data.aws_iam_policy_document.remediation.json
}

resource "aws_cloudwatch_log_group" "remediation" {
  name              = "/aws/lambda/${local.remediation_name}"
  retention_in_days = var.log_retention_days
}

data "archive_file" "remediation" {
  type        = "zip"
  source_dir  = var.remediation_source_dir
  output_path = "${path.root}/.build/${local.remediation_name}.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "remediation" {
  function_name    = local.remediation_name
  role             = aws_iam_role.remediation.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.handler"
  memory_size      = 128
  timeout          = 30
  layers           = [var.powertools_layer_arn]
  filename         = data.archive_file.remediation.output_path
  source_code_hash = data.archive_file.remediation.output_base64sha256

  environment {
    variables = {
      TARGET_FUNCTION_NAME    = var.target_function_name
      TARGET_ALIAS_NAME       = var.target_alias_name
      LAST_KNOWN_GOOD_PARAM   = var.last_known_good_param_name
      ALERT_TOPIC_ARN         = var.alert_topic_arn
      POWERTOOLS_SERVICE_NAME = local.remediation_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.remediation, aws_iam_role_policy.remediation]
}

# ---------------------------------------------------------------------------
# EventBridge: 5xx-rate 알람이 ALARM으로 바뀔 때만 복구 Lambda 호출
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "rollback" {
  name        = "${var.name_prefix}-rollback-on-5xx-rate"
  description = "Invoke remediation Lambda when the 5xx-rate alarm enters ALARM"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    resources     = [aws_cloudwatch_metric_alarm.error_rate.arn]
    detail = {
      state = { value = ["ALARM"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "rollback" {
  rule = aws_cloudwatch_event_rule.rollback.name
  arn  = aws_lambda_function.remediation.arn

  retry_policy {
    maximum_retry_attempts       = 2
    maximum_event_age_in_seconds = 600
  }
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rollback.arn
}

# ---------------------------------------------------------------------------
# 대시보드
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.name_prefix

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "alarm", x = 0, y = 0, width = 24, height = 2
        properties = {
          title  = "Alarms"
          alarms = [aws_cloudwatch_metric_alarm.error_rate.arn, aws_cloudwatch_metric_alarm.error_count.arn, aws_cloudwatch_metric_alarm.latency.arn]
        }
      },
      {
        type = "metric", x = 0, y = 2, width = 8, height = 6
        properties = {
          title  = "Requests / 4xx / 5xx"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", var.api_id],
            [".", "4xx", ".", "."],
            [".", "5xx", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 2, width = 8, height = 6
        properties = {
          title  = "5xx rate (%)"
          region = var.region
          period = 60
          yAxis  = { left = { min = 0, max = 100 } }
          metrics = [
            [{ expression = "100 * FILL(e, 0) / c", label = "5xx rate", id = "rate" }],
            ["AWS/ApiGateway", "Count", "ApiId", var.api_id, { id = "c", stat = "Sum", visible = false }],
            [".", "5xx", ".", ".", { id = "e", stat = "Sum", visible = false }],
          ]
          annotations = { horizontal = [{ value = 5, label = "rollback threshold" }] }
        }
      },
      {
        type = "metric", x = 16, y = 2, width = 8, height = 6
        properties = {
          title  = "API latency (ms)"
          region = var.region
          period = 60
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiId", var.api_id, { stat = "p50" }],
            ["...", { stat = "p99" }],
          ]
          annotations = { horizontal = [{ value = 3000, label = "p99 alarm" }] }
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 12, height = 6
        properties = {
          title  = "Lambda errors / throttles / duration"
          region = var.region
          period = 60
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", var.target_function_name, { stat = "Sum" }],
            [".", "Throttles", ".", ".", { stat = "Sum" }],
            [".", "Duration", ".", ".", { stat = "p99", yAxis = "right" }],
          ]
        }
      },
      {
        type = "log", x = 12, y = 8, width = 12, height = 6
        properties = {
          title  = "Auto-rollback history"
          region = var.region
          query  = "SOURCE '${aws_cloudwatch_log_group.remediation.name}' | fields @timestamp, message, alarm, from, to | filter message like /Rolled back|no rollback/ | sort @timestamp desc | limit 20"
          view   = "table"
        }
      },
    ]
  })
}
