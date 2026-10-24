output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  value = aws_eks_cluster.this.version
}

output "cluster_certificate_authority" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "클러스터가 만든 기본 보안그룹. 노드·컨트롤 플레인이 같이 쓰며 RDS 인바운드 허용의 소스로 쓴다"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "system_node_role_arn" {
  value = aws_iam_role.node.arn
}

output "pod_identity_assume_role_policy" {
  description = "Pod Identity 용 역할을 다른 모듈에서 만들 때 재사용하는 신뢰 정책"
  value       = data.aws_iam_policy_document.pod_identity_assume.json
}
