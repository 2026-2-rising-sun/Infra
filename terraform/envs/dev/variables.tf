variable "project" {
  description = "리소스 태깅/네이밍에 쓰는 프로젝트 식별자"
  type        = string
  default     = "shoppinglive"
}

variable "environment" {
  description = "환경 식별자 (dev / perf / demo)"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "리소스를 생성할 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

# TODO: 실제 모듈을 채우면서 vpc_cidr, eks_version, node_instance_types,
#       rds_instance_class 등 모듈별 입력 변수를 여기에 추가한다.
