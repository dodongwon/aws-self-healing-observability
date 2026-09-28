variable "name_prefix" {
  type = string
}

variable "lambda_function_name" {
  type = string
}

variable "lambda_alias_name" {
  type = string
}

variable "lambda_alias_invoke_arn" {
  type = string
}

variable "throttle_rate" {
  description = "초당 요청 제한 (비용 폭주 방지)"
  type        = number
}

variable "throttle_burst" {
  type = number
}

variable "log_retention_days" {
  type = number
}
