# dev 환경 루트 모듈 — 현재는 골격만 존재한다.
#
# 팀이 AWS 사용 범위(계정/리전/비용 한도)를 합의한 뒤 아래 모듈을 차례로 채운다.
# 모듈 골격은 ../../modules/{network,eks,rds,ivs} 에 있다.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# TODO(network): VPC / subnet / NAT / security group 정의
# module "network" {
#   source = "../../modules/network"
# }

# TODO(eks): EKS 클러스터 + 노드그룹 정의 (k8s/overlays/dev 가 배포될 대상)
# module "eks" {
#   source = "../../modules/eks"
# }

# TODO(rds): 서비스별 PostgreSQL 데이터베이스 정의
#            (로컬은 단일 컨테이너 다중 DB, 클라우드 구성은 별도 합의 필요)
# module "rds" {
#   source = "../../modules/rds"
# }

# TODO(ivs): 라이브 방송용 AWS IVS 채널 정의
# module "ivs" {
#   source = "../../modules/ivs"
# }
