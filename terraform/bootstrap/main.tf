# Terraform 상태 저장소. envs/dev 보다 먼저, 딱 한 번 apply 한다.
#
# 상태 파일을 S3 에 두면 노트북이 바뀌어도 같은 상태를 이어 쓰고, DynamoDB 잠금으로 두 사람이 동시에 apply 하는 사고를 막는다.
# 이 루트 모듈 자체의 상태는 로컬 파일이다(닭과 달걀). 버킷 하나·테이블 하나라 잃어버려도 import 로 복구된다.
# 이 두 자원은 클러스터를 지울 때도 남겨 둔다. 비용은 월 몇 센트다.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
    }
  }

  backend "local" {
    path = "terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # 버킷 이름은 전 세계에서 유일해야 해서 계정 ID 를 붙인다.
  bucket_name = "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # 잘못 apply 했을 때 이전 상태로 돌아가기 위해
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "lock" {
  name         = "${var.project}-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
