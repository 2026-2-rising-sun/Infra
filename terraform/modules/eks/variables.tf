variable "cluster_name" {
  description = "EKS 클러스터 이름. 서브넷·보안그룹 태그, IAM 역할 이름의 기준"
  type        = string
}

variable "kubernetes_version" {
  description = "EKS 쿠버네티스 버전. 표준 지원 기간(출시 후 14개월) 안의 버전만 쓴다"
  type        = string
}

variable "private_subnet_ids" {
  description = "컨트롤 플레인 ENI 와 노드가 들어갈 프라이빗 서브넷"
  type        = list(string)
}

variable "public_access_cidrs" {
  description = "퍼블릭 API 엔드포인트에 접근할 수 있는 CIDR. 작업자 IP 로 좁힌다"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "system_instance_types" {
  description = "시스템 노드 그룹 인스턴스 타입(arm64). 첫 번째가 우선이고 나머지는 재고가 없을 때 대체"
  type        = list(string)
  default     = ["t4g.medium"]
}

variable "system_node_count" {
  description = "시스템 노드 수. Karpenter·ArgoCD·Envoy 가 올라가며 2대면 한 대가 교체돼도 버틴다"
  type        = number
  default     = 2
}

variable "cluster_log_types" {
  description = "CloudWatch 로 보낼 컨트롤 플레인 로그. 비어 있으면 비용이 안 든다. 감사가 필요하면 [\"api\", \"audit\"]"
  type        = list(string)
  default     = []
}
