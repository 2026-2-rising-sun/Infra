# terraform/modules/eks

EKS 클러스터, 시스템 노드 그룹(2대), 애드온, EBS CSI 의 Pod Identity.

## 결정한 것

| 항목 | 결정 | 이유 |
|---|---|---|
| 지원 정책 | `support_type = STANDARD` | 연장 지원으로 넘어가면 시간당 $0.10 → $0.60. 종료 전에 버전을 올린다 |
| 인증 | Access Entry(API) 만 | aws-auth ConfigMap 을 손으로 고치는 방식은 실수가 잦다. 만든 사람이 자동 관리자 |
| 파드 권한 | Pod Identity | IRSA 와 달리 OIDC 공급자 등록이 없고 신뢰 정책이 한 줄. 애드온·Karpenter·LB 컨트롤러 모두 같은 방식 |
| 시스템 노드 | t4g.medium × 2, 온디맨드 | Karpenter·ArgoCD·Envoy·CoreDNS 가 올라간다. Karpenter 가 자기 노드를 만들 수는 없다 |
| 애드온 버전 | 고정하지 않음 (`most_recent`) | 클러스터 버전을 올릴 때마다 다섯 줄을 같이 고치는 것보다 호환 범위 안 최신이 안전 |
| 기본 애드온 | `bootstrap_self_managed_addons = false` | vpc-cni·kube-proxy·coredns 를 EKS 관리형 애드온으로 둬야 업그레이드가 한 곳에서 된다 |
| 컨트롤 플레인 로그 | 끔 | CloudWatch 비용. 감사가 필요하면 `cluster_log_types` |

## 버전

`kubernetes_version` 은 루트에서 넘긴다. 표준 지원은 출시 후 14개월. 생성 전 `aws eks describe-cluster-versions --region ap-northeast-2` 로 확인.
