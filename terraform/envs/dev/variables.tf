variable "project" {
  description = "리소스 태깅/네이밍에 쓰는 프로젝트 식별자"
  type        = string
  default     = "shoppinglive"
}

variable "environment" {
  description = "환경 식별자 (dev / perf / demo)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "리소스를 생성할 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

# EKS 표준 지원 기간(출시 후 14개월)이 끝나면 시간당 요금이 6배가 된다. 지원 종료 전에 올린다.
# 2026-10 기준 값. 실제 생성 전에 `aws eks describe-cluster-versions` 로 표준 지원 중인지 확인한다.
variable "eks_version" {
  type    = string
  default = "1.36"
}

variable "eks_public_access_cidrs" {
  description = "kubectl 을 쓸 작업자 IP. 비우지 말고 자기 공인 IP/32 로 좁힌다"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "rds_instance_class" {
  type    = string
  default = "db.t4g.small"
}

variable "domain_name" {
  description = "서비스 도메인. Route 53 에 호스팅 영역이 있어야 한다"
  type        = string
}

variable "hosted_zone_id" {
  description = "domain_name 의 Route 53 호스팅 영역 ID"
  type        = string
}

variable "bucket_suffix" {
  description = "S3 버킷 이름을 전 세계에서 유일하게 만들 접미사 (예: 계정 ID 뒤 6자리)"
  type        = string
}

variable "nlb_dns_name" {
  description = "Envoy Gateway 의 NLB DNS 이름. 클러스터와 Gateway 를 올린 뒤 채우고 두 번째 apply 를 한다"
  type        = string
  default     = null
}

variable "origin_verify_secret" {
  description = "CloudFront → NLB 비밀 헤더 값. `openssl rand -hex 32` 로 만들어 tfvars 에만 둔다"
  type        = string
  sensitive   = true
}

variable "budget_alert_email" {
  description = "예산 알림을 받을 메일 주소"
  type        = string
}
