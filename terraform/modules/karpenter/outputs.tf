output "node_role_name" {
  description = "EC2NodeClass.spec.role 에 넣는 값"
  value       = aws_iam_role.node.name
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "controller_role_arn" {
  value = aws_iam_role.controller.arn
}

output "interruption_queue_name" {
  description = "Helm values 의 settings.interruptionQueue 에 넣는 값"
  value       = aws_sqs_queue.interruption.name
}
