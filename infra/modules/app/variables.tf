variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "name_prefix" {
  type = string
}

variable "source_dir" {
  description = "앱 Lambda 소스 디렉토리"
  type        = string
}

variable "powertools_layer_arn" {
  type = string
}

variable "metrics_namespace" {
  type = string
}

variable "log_retention_days" {
  type = number
}
