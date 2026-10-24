variable "namespace" {
  description = "저장소 이름 접두사. <namespace>/<service> 형태가 된다"
  type        = string
  default     = "shoppinglive"
}

variable "services" {
  description = "저장소를 만들 서비스 이름. k8s/base 의 Deployment 이름과 같다"
  type        = list(string)
  default     = ["member-service", "shopping-service", "commerce-service", "live-service", "notification-service"]
}

variable "keep_images" {
  type    = number
  default = 10
}
