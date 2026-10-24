output "address" {
  description = "Backend POSTGRES 호스트로 넣는 값"
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "master_user_secret_arn" {
  description = "RDS 가 만든 마스터 비밀번호 Secret. External Secrets 가 읽는다"
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  value = aws_security_group.this.id
}
