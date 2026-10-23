# dev 환경 루트 모듈. 설계안 5장의 모듈을 여기서 잇는다.
#
# 원칙: 필요할 때만 만든다. `make aws-up` 으로 만들고 작업이 끝나면 `make aws-down` 으로 지운다.
# 남겨 두는 것은 상태 저장소(terraform/bootstrap)와 ECR 이미지뿐이다.
#
# 적용 순서(모듈 의존 관계):
#   network → eks → (karpenter, nlb, rds) → edge → ci
# edge 는 NLB 주소(nlb_dns_name)가 생긴 뒤 한 번 더 apply 해야 /api/* 가 연결된다. 자세한 건 modules/edge/README.md.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70"
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

# CloudFront 인증서·WAF 전용. 다른 자원은 만들지 않는다.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = local.name
}

module "network" {
  source = "../../modules/network"

  name         = local.name
  aws_region   = var.aws_region
  vpc_cidr     = var.vpc_cidr
  cluster_name = local.cluster_name
}

module "eks" {
  source = "../../modules/eks"

  cluster_name        = local.cluster_name
  kubernetes_version  = var.eks_version
  private_subnet_ids  = module.network.private_subnet_ids
  public_access_cidrs = var.eks_public_access_cidrs
}

module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name = module.eks.cluster_name
  cluster_arn  = module.eks.cluster_arn
}

module "nlb" {
  source = "../../modules/nlb"

  cluster_name = module.eks.cluster_name
  vpc_id       = module.network.vpc_id
  vpc_cidr     = module.network.vpc_cidr
}

module "rds" {
  source = "../../modules/rds"

  name                     = local.name
  vpc_id                   = module.network.vpc_id
  private_subnet_ids       = module.network.private_subnet_ids
  source_security_group_id = module.eks.cluster_security_group_id
  instance_class           = var.rds_instance_class
}

module "ecr" {
  source = "../../modules/ecr"

  namespace = var.project
}

module "edge" {
  source = "../../modules/edge"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name                 = local.name
  domain_name          = var.domain_name
  hosted_zone_id       = var.hosted_zone_id
  frontend_bucket_name = "${local.name}-frontend-${var.bucket_suffix}"
  nlb_dns_name         = var.nlb_dns_name
  origin_verify_secret = var.origin_verify_secret
}

module "ci" {
  source = "../../modules/ci"

  name                        = local.name
  ecr_repository_arns         = module.ecr.repository_arns
  frontend_bucket_arn         = module.edge.frontend_bucket_arn
  cloudfront_distribution_arn = module.edge.distribution_arn
}
