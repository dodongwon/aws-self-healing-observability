output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

output "error_rate_alarm_name" {
  value = aws_cloudwatch_metric_alarm.error_rate.alarm_name
}

output "remediation_function_name" {
  value = aws_lambda_function.remediation.function_name
}
