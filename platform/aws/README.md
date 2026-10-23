# platform/aws

EKS 클러스터 안에 들어가는 것 중 **AWS 에만 있는** 부품. kind 와 공유하는 부품(Envoy Gateway, Strimzi, KEDA)은 kind 에서는 `platform/kind/components/*.sh` 가 helm 으로 깔고, AWS 에서는 같은 차트·같은 버전을 ArgoCD(`argocd/applications/platform/`)가 관리한다. GatewayClass 는 1단계의 `platform/kind/envoy-gateway/gatewayclass.yaml` 을 그대로 쓴다.

```
platform/aws/
├── up.sh / down.sh          # make aws-up / aws-down 의 본체
├── install.sh               # 클러스터 부품 설치 (terraform apply 뒤)
├── rds-init.sh + rds/init.sql
├── values/                  # Helm values: aws-load-balancer-controller, karpenter, argocd
├── karpenter/               # EC2NodeClass 1, NodePool 2 (app: 스팟 허용 / kafka: 온디맨드 + taint)
└── envoy-gateway/           # EnvoyProxy(NLB 어노테이션), Gateway 패치 예시
```

`__대문자__` 자리는 `install.sh` 가 Terraform output 으로 바꿔 넣는다. 파일을 직접 `kubectl apply` 하지 않는다.

## 왜 kind 와 AWS 를 나눴나

같은 YAML 로 두 곳을 돌리는 게 원칙이지만, 노드를 만드는 것(Karpenter)과 NLB 를 만드는 것(로드밸런서 컨트롤러)은 kind 에 대응물이 없다. 이 둘과 ArgoCD 만 여기 두고 나머지는 공유한다.

## 노드 배치 규약

| 라벨/taint | 누가 올라가나 |
|---|---|
| `shoppinglive.io/node-role=system` (노드 그룹) | Karpenter, LB 컨트롤러, ArgoCD, Envoy, Strimzi 오퍼레이터, KEDA, CoreDNS |
| `shoppinglive.io/node-role=app` (Karpenter app 풀) | 서비스 5개, Redis, 관측 스택 |
| `shoppinglive.io/node-role=kafka` + taint `workload=kafka` (Karpenter kafka 풀) | Kafka 브로커만. Kafka CR 에 toleration·nodeSelector 필요 |
