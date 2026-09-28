output "function_name" {
  value = aws_lambda_function.api.function_name
}

output "function_arn" {
  value = aws_lambda_function.api.arn
}

output "alias_name" {
  value = aws_lambda_alias.live.name
}

output "alias_arn" {
  value = aws_lambda_alias.live.arn
}

output "alias_invoke_arn" {
  value = aws_lambda_alias.live.invoke_arn
}

output "table_name" {
  value = aws_dynamodb_table.items.name
}

output "last_known_good_param_name" {
  value = aws_ssm_parameter.last_known_good.name
}

output "last_known_good_param_arn" {
  value = aws_ssm_parameter.last_known_good.arn
}
