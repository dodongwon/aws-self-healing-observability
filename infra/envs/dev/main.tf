terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  # 자격증명은 환경에서 주입: 로컬은 AWS_PROFILE=personal, CI는 OIDC
  backend "s3" {
    bucket       = "obs-app-tfstate-927750239250"
    key          = "envs/dev/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"
  repo_root   = "${path.root}/../../.."
}

# Powertools 공개 Layer 최신 버전 (AWS가 SSM 공개 파라미터로 제공)
data "aws_ssm_parameter" "powertools_layer" {
  name = "/aws/service/powertools/python/arm64/python3.12/latest"
}

module "app" {
  source = "../../modules/app"

  project              = var.project
  environment          = var.environment
  name_prefix          = local.name_prefix
  source_dir           = "${local.repo_root}/src/app"
  powertools_layer_arn = nonsensitive(data.aws_ssm_parameter.powertools_layer.value)
  metrics_namespace    = var.metrics_namespace
  log_retention_days   = var.log_retention_days
}

module "api" {
  source = "../../modules/api"

  name_prefix             = local.name_prefix
  lambda_function_name    = module.app.function_name
  lambda_alias_name       = module.app.alias_name
  lambda_alias_invoke_arn = module.app.alias_invoke_arn
  throttle_rate           = var.throttle_rate
  throttle_burst          = var.throttle_burst
  log_retention_days      = var.log_retention_days
}

data "aws_caller_identity" "current" {}

module "notification" {
  source = "../../modules/notification"

  project            = var.project
  name_prefix        = local.name_prefix
  region             = var.region
  account_id         = data.aws_caller_identity.current.account_id
  alert_email        = var.alert_email
  monthly_budget_usd = var.monthly_budget_usd
}

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix                = local.name_prefix
  region                     = var.region
  api_id                     = module.api.api_id
  target_function_name       = module.app.function_name
  target_function_arn        = module.app.function_arn
  target_alias_name          = module.app.alias_name
  last_known_good_param_name = module.app.last_known_good_param_name
  last_known_good_param_arn  = module.app.last_known_good_param_arn
  alert_topic_arn            = module.notification.topic_arn
  remediation_source_dir     = "${local.repo_root}/src/remediation"
  powertools_layer_arn       = nonsensitive(data.aws_ssm_parameter.powertools_layer.value)
  log_retention_days         = var.log_retention_days
}
