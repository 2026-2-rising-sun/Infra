# platform/aws/install.sh 와 Makefile 이 읽는 값들. 이름을 바꾸면 스크립트도 같이 고친다.

output "cluster_name" {
  value = module.eks.cluster_name
}

output "aws_region" {
  value = var.aws_region
}

output "karpenter_node_role_name" {
  value = module.karpenter.node_role_name
}

output "karpenter_interruption_queue" {
  value = module.karpenter.interruption_queue_name
}

output "nlb_security_group_id" {
  value = module.nlb.nlb_security_group_id
}

output "origin_certificate_arn" {
  value = module.edge.origin_certificate_arn
}

output "cloudfront_distribution_id" {
  value = module.edge.distribution_id
}

output "frontend_bucket_name" {
  value = module.edge.frontend_bucket_name
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "rds_address" {
  value = module.rds.address
}

output "rds_master_user_secret_arn" {
  value = module.rds.master_user_secret_arn
}

output "github_actions_role_arn" {
  value = module.ci.actions_role_arn
}

output "cluster_arn" {
  value = module.eks.cluster_arn
}

output "origin_verify_secret" {
  value     = var.origin_verify_secret
  sensitive = true
}
