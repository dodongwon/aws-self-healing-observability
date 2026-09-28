variable "name_prefix" {
  type = string
}

variable "region" {
  type = string
}

variable "api_id" {
  type = string
}

variable "target_function_name" {
  type = string
}

variable "target_function_arn" {
  type = string
}

variable "target_alias_name" {
  type = string
}

variable "last_known_good_param_name" {
  type = string
}

variable "last_known_good_param_arn" {
  type = string
}

variable "alert_topic_arn" {
  type = string
}

variable "remediation_source_dir" {
  type = string
}

variable "powertools_layer_arn" {
  type = string
}

variable "log_retention_days" {
  type = number
}
