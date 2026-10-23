output "repository_urls" {
  description = "서비스 이름 → 이미지 URL. kustomize images.newName 에 넣는다"
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_arns" {
  value = [for repo in aws_ecr_repository.this : repo.arn]
}
