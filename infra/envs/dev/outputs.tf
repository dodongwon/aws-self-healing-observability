output "api_endpoint" {
  value = module.api.api_endpoint
}

output "function_name" {
  value = module.app.function_name
}

output "alias_name" {
  value = module.app.alias_name
}

output "last_known_good_param" {
  value = module.app.last_known_good_param_name
}

output "dashboard_name" {
  value = module.monitoring.dashboard_name
}

output "error_rate_alarm_name" {
  value = module.monitoring.error_rate_alarm_name
}
