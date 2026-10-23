output "nlb_security_group_id" {
  description = "Envoy Gateway Service 의 aws-load-balancer-security-groups 어노테이션에 넣는 값"
  value       = aws_security_group.nlb.id
}

output "controller_role_arn" {
  value = aws_iam_role.controller.arn
}
