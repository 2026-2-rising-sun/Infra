variable "name" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "DB 서브넷 그룹에 넣을 프라이빗 서브넷 (2 AZ 이상 필요)"
  type        = list(string)
}

variable "source_security_group_id" {
  description = "5432 접근을 허용할 보안그룹 (EKS 클러스터 보안그룹)"
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL 메이저 버전. 마이너는 RDS 가 자동 패치한다"
  type        = string
  default     = "17"
}

variable "instance_class" {
  description = "설계안 기준 db.t4g.small. 부하 테스트에서 병목이면 올린다"
  type        = string
  default     = "db.t4g.small"
}

variable "allocated_storage_gb" {
  type    = number
  default = 20
}

variable "master_username" {
  type    = string
  default = "shoppinglive"
}
