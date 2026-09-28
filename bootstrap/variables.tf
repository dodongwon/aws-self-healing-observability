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

# GitHub immutable subject 형식: repo:<owner>@<owner_id>/<repo>@<repo_id>
# 레포 이름이 바뀌거나 같은 이름의 레포가 새로 생겨도 ID가 달라 신뢰 조건이 오용되지 않는다.
# 확인: gh api repos/<owner>/<repo>/actions/oidc/customization/sub
variable "github_oidc_sub_prefix" {
  description = "OIDC 신뢰 대상 GitHub 레포의 sub 클레임 접두사"
  type        = string
  default     = "repo:dodongwon@244634602/aws-self-healing-observability@1392422946"
}
