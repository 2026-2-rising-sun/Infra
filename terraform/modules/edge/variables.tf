variable "name" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "domain_name" {
  description = "서비스 도메인 (예: shoppinglive.example.com). Route 53 호스팅 영역 안에 있어야 한다"
  type        = string
}

variable "hosted_zone_id" {
  description = "domain_name 이 속한 Route 53 호스팅 영역 ID"
  type        = string
}

variable "frontend_bucket_name" {
  description = "Vite 빌드 결과(dist/)를 올릴 S3 버킷 이름. 전 세계에서 유일해야 한다"
  type        = string
}

variable "api_origin_hostname" {
  description = "CloudFront 가 /api/* 를 보낼 오리진 호스트. 비우면 api-origin.<domain_name>"
  type        = string
  default     = null
}

variable "nlb_dns_name" {
  description = "클러스터 안 로드밸런서 컨트롤러가 만든 NLB 의 DNS 이름. 생기기 전엔 null 로 둔다"
  type        = string
  default     = null
}

variable "origin_verify_secret" {
  description = "CloudFront 가 오리진 요청에 붙이는 X-Origin-Verify 값. Envoy 가 같은 값을 검사한다"
  type        = string
  sensitive   = true
}

variable "rate_limit_per_5min" {
  description = "IP 당 5분 요청 상한. WAF 레이트 기반 규칙의 최소값은 10 이다"
  type        = number
  default     = 2000
}

variable "price_class" {
  description = "엣지 범위. PriceClass_200 은 북미·유럽·아시아(서울 포함), PriceClass_All 은 남미·호주까지"
  type        = string
  default     = "PriceClass_200"
}
