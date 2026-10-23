output "actions_role_arn" {
  description = "워크플로의 aws-actions/configure-aws-credentials role-to-assume 에 넣는 값"
  value       = aws_iam_role.actions.arn
}
