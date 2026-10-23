# terraform/modules/nlb

이름은 nlb 지만 NLB 를 직접 만들지는 않는다. NLB 는 클러스터 안 **AWS Load Balancer Controller** 가 Envoy Gateway 의 `type: LoadBalancer` Service 를 보고 만든다. 이 모듈은 그 컨트롤러의 IAM 역할(Pod Identity)과 NLB 에 붙일 보안그룹만 만든다.

## 왜 Terraform 이 NLB 를 만들지 않나

NLB 의 타깃은 Envoy 파드 IP 인데 파드는 수시로 바뀐다. 컨트롤러가 Service → NLB 를 통째로 관리해야 타깃 갱신·삭제가 한 곳에서 일어난다. Terraform 이 만들면 `make aws-down` 때 NLB 가 남아 과금되는 사고가 나기 쉽다.

## 보안그룹

`com.amazonaws.global.cloudfront.origin-facing` 관리형 프리픽스 리스트에서 오는 443 만 받는다. CloudFront 를 거치지 않은 요청은 TCP 단계에서 막힌다. 2차 방어로 Envoy 가 `X-Origin-Verify` 헤더를 본다.

## 쿠버네티스 쪽 설정

`platform/aws/envoy-gateway/envoyproxy-nlb.yaml` 의 Service 어노테이션에 이 모듈의 보안그룹 ID 와 edge 모듈의 서울 인증서 ARN 을 넣는다. `make aws-up` 이 Terraform output 을 읽어 채운다.

## 정책 파일 갱신

`lb-controller-iam-policy.json` = 컨트롤러 v3.6.1 의 `docs/install/iam_policy.json`. 컨트롤러 버전을 올릴 때 같은 경로에서 다시 받는다.
