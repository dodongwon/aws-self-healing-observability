variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "로컬 apply에 사용할 AWS CLI 프로필 (개인 계정)"
  type        = string
  default     = "personal"
}

variable "project" {
  description = "리소스 이름 접두사"
  type        = string
  default     = "obs-app"
}

variable "github_repo" {
  description = "OIDC 신뢰 대상 GitHub 레포 (owner/name)"
  type        = string
  default     = "dodongwon/aws-self-healing-observability"
}
