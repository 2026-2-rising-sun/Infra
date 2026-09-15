# 상태 파일 백엔드 설정.
#
# 지금은 로컬 백엔드로 두고, 팀이 AWS 계정을 확보하면 S3 + DynamoDB 잠금으로 전환한다.
# 전환 시 아래 local 블록을 지우고 s3 블록의 주석을 해제한 뒤 `terraform init -migrate-state` 를 실행한다.

terraform {
  backend "local" {
    path = "terraform.tfstate"
  }

  # TODO: 원격 상태로 전환
  # backend "s3" {
  #   bucket         = "shoppinglive-tfstate"
  #   key            = "envs/dev/terraform.tfstate"
  #   region         = "ap-northeast-2"
  #   dynamodb_table = "shoppinglive-tfstate-lock"
  #   encrypt        = true
  # }
}
