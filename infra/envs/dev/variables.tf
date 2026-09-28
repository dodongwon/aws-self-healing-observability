variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "project" {
  type    = string
  default = "obs-app"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "metrics_namespace" {
  type    = string
  default = "ObsApp"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "throttle_rate" {
  type    = number
  default = 10
}

variable "throttle_burst" {
  type    = number
  default = 20
}

variable "alert_email" {
  description = "알람·예산 경보 수신 이메일 — 커밋하지 않고 TF_VAR_alert_email 로 주입"
  type        = string
  sensitive   = true
}

variable "monthly_budget_usd" {
  type    = string
  default = "10"
}
