variable "cluster_name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr" {
  description = "NLB 가 타깃(Envoy 파드)으로 나가는 범위"
  type        = string
}
