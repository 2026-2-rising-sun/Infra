variable "name" {
  description = "역할 이름 접두사"
  type        = string
}

variable "github_repositories" {
  description = "이 역할을 빌릴 수 있는 GitHub 리포지토리 (org/repo)"
  type        = list(string)
  default     = ["2026-2-rising-sun/Backend", "2026-2-rising-sun/Frontend", "2026-2-rising-sun/Infra"]
}

variable "ecr_repository_arns" {
  description = "이미지를 푸시할 ECR 저장소 ARN"
  type        = list(string)
}

variable "frontend_bucket_arn" {
  description = "Vite 빌드 결과를 올릴 S3 버킷 ARN"
  type        = string
}

variable "cloudfront_distribution_arn" {
  description = "배포 후 무효화할 CloudFront 배포 ARN"
  type        = string
}
