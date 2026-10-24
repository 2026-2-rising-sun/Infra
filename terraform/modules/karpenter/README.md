# terraform/modules/karpenter

Karpenter 컨트롤러가 쓰는 AWS 자원. 컨트롤러 설치(Helm)와 NodePool/EC2NodeClass(YAML)는 `platform/aws/` 에 있다.

| 자원 | 용도 |
|---|---|
| 노드 IAM 역할 + Access Entry | Karpenter 가 만든 EC2 가 클러스터에 합류하고 ECR·SSM 을 쓴다 |
| 컨트롤러 IAM 역할 (Pod Identity) | EC2 생성·삭제, 가격 조회, 인스턴스 프로파일 관리. 정책은 Karpenter 공식 CloudFormation 의 범위를 따라 "이 클러스터 태그가 붙은 자원"으로 좁혔다 |
| SQS 큐 + EventBridge 규칙 4개 | 스팟 중단 2분 전 경고, 리밸런스 권고, 예정 점검, 인스턴스 상태 변화를 받아 파드를 미리 옮긴다 |

## 왜 Cluster Autoscaler 가 아니라 Karpenter 인가

Cluster Autoscaler 는 노드 그룹 단위로만 늘리므로 "지금 Pending 인 파드에 딱 맞는 크기"를 못 고른다.
Karpenter 는 파드 요구량을 보고 인스턴스 타입을 그때 고르고, 스팟 가격이 싼 타입을 자동으로 섞는다.
방송 시작 순간 live 파드가 한꺼번에 늘어나는 우리 패턴에선 노드 추가 지연이 짧은 쪽이 맞다.

## 컨트롤러 정책 주의

`controller-policy.json.tftpl` 은 Karpenter v1.x 공식 정책을 옮긴 것이다. Karpenter 를 올릴 때
[공식 CloudFormation](https://github.com/aws/karpenter-provider-aws/blob/main/website/content/en/preview/reference/cloudformation.md) 과 대조해 Sid 가 늘었는지 확인한다.
