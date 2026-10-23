output "distribution_id" {
  description = "Frontend 배포 워크플로가 무효화할 때 쓰는 ID"
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  value = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "frontend_bucket_name" {
  value = aws_s3_bucket.frontend.bucket
}

output "frontend_bucket_arn" {
  value = aws_s3_bucket.frontend.arn
}

output "origin_certificate_arn" {
  description = "NLB TLS 리스너에 붙일 서울 인증서. Envoy Gateway Service 의 ssl-cert 어노테이션에 넣는다"
  value       = aws_acm_certificate_validation.origin.certificate_arn
}

output "api_origin_hostname" {
  value = local.api_origin_hostname
}
