output "state_bucket" {
  description = "envs/*/backend.hcl 의 bucket 에 넣는 값"
  value       = aws_s3_bucket.state.bucket
}

output "lock_table" {
  description = "envs/*/backend.hcl 의 dynamodb_table 에 넣는 값"
  value       = aws_dynamodb_table.lock.name
}
