variable "cluster_name" {
  description = "Karpenter 가 노드를 붙일 EKS 클러스터 이름"
  type        = string
}

variable "cluster_arn" {
  description = "eks:DescribeCluster 권한 범위를 이 클러스터로 좁히기 위한 ARN"
  type        = string
}

variable "namespace" {
  description = "Karpenter 컨트롤러가 설치될 네임스페이스 (Pod Identity 연결 대상)"
  type        = string
  default     = "karpenter"
}

variable "service_account" {
  description = "Karpenter Helm 차트가 만드는 ServiceAccount 이름"
  type        = string
  default     = "karpenter"
}
