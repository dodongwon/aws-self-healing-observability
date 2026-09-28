variable "project" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "alert_email" {
  description = "알람·예산 경보 수신 이메일 (레포에 커밋하지 않고 TF_VAR_alert_email로 주입)"
  type        = string
  sensitive   = true
}

variable "monthly_budget_usd" {
  type = string
}
