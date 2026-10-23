# terraform/modules/edge

S3(비공개, OAC) + CloudFront + WAF + ACM 두 장 + Route 53. 설계안 3.1 의 "브라우저 → CloudFront" 구간 전체.

## 결정한 것

| 항목 | 결정 | 이유 |
|---|---|---|
| S3 접근 | OAC 만 | 버킷을 공개로 열지 않는다. 정적 웹사이트 엔드포인트는 OAC 를 못 써서 SPA 폴백은 CloudFront Function 으로 |
| `/api/*` 캐시 | `CachingDisabled` + `AllViewerExceptHostHeader` | Authorization·쿠키를 그대로 전달하고 아무것도 캐시하지 않는다. Host 는 오리진 것으로 바뀌어야 NLB 인증서와 맞는다 |
| 오리진 주소 | `api-origin.<도메인>` CNAME | NLB 는 클러스터 안 컨트롤러가 만들어서 Terraform 이 주소를 모른다. CNAME 만 나중에 채우면 CloudFront 를 다시 안 만든다 |
| 오리진 타임아웃 | 60초 | SSE heartbeat 15초. 60초 넘기려면 AWS 한도 상향 필요 |
| 비밀 헤더 | `X-Origin-Verify` | CloudFront 를 우회해 NLB 로 직접 오는 요청을 Envoy 가 거부한다. 1차 방어는 NLB 보안그룹(CloudFront IP 만) |
| WAF | 관리형 3종 + IP 레이트리밋 | 설계안 6장. 부하 테스트 IP 는 한도에 걸릴 수 있어 변수로 조절 |

## 두 번 apply 하는 이유

1. 클러스터를 만들고 Envoy Gateway 를 올리면 로드밸런서 컨트롤러가 NLB 를 만든다.
2. `kubectl -n envoy-gateway-system get svc` 로 NLB 주소를 읽어 `nlb_dns_name` 에 넣고 다시 apply 한다. CNAME 한 줄만 추가된다.

`make aws-up` 이 이 순서를 자동으로 한다.
