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

variable "github_refs" {
  description = "배포 역할을 허용할 정확한 Git 브랜치 ref. PR·와일드카드는 허용하지 않는다"
  type        = list(string)
  default     = ["refs/heads/dev", "refs/heads/main"]
  validation {
    condition     = length(var.github_refs) > 0 && alltrue([for ref in var.github_refs : startswith(ref, "refs/heads/") && !strcontains(ref, "*") && !strcontains(ref, "?")])
    error_message = "배포 브랜치의 정확한 refs/heads/ 경로를 지정해야 한다."
  }
}
