# 상태 파일 백엔드. terraform/bootstrap 이 만든 S3 버킷 + DynamoDB 잠금을 쓴다.
#
# 버킷 이름에 계정 ID 가 들어가서 여기 고정하지 않고 backend.hcl 로 넘긴다:
#   terraform -chdir=terraform/envs/dev init -backend-config=backend.hcl
# backend.hcl 은 backend.hcl.example 을 복사해 채운다(git 에 넣지 않는다).
# CI 의 validate 는 -backend=false 라 이 블록을 읽지 않는다.

terraform {
  backend "s3" {}
}
