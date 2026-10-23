variable "name" {
  description = "리소스 이름 접두사 (예: shoppinglive-dev)"
  type        = string
}

variable "aws_region" {
  description = "AZ 이름을 만들 때 쓰는 리전"
  type        = string
}

variable "az_suffixes" {
  description = "쓸 AZ 접미사. 서울은 a·c 가 모든 인스턴스 타입을 지원해서 기본값으로 둔다"
  type        = list(string)
  default     = ["a", "c"]
}

variable "vpc_cidr" {
  description = "VPC CIDR. /16 을 /20 단위로 잘라 서브넷을 만든다"
  type        = string
  default     = "10.20.0.0/16"
}

variable "cluster_name" {
  description = "서브넷 태그에 넣을 EKS 클러스터 이름 (로드밸런서 컨트롤러·Karpenter 가 서브넷을 찾는 기준)"
  type        = string
}
