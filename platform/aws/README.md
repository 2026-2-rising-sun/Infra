# platform/aws

EKS 클러스터 안에 들어가는 것 중 **AWS 에만 있는** 부품. kind 와 공유하는 부품(Envoy Gateway, Strimzi, KEDA)은 kind 에서는 `platform/kind/components/*.sh` 가 helm 으로 깔고, AWS 에서는 같은 차트·같은 버전을 ArgoCD(`argocd/applications/platform/`)가 관리한다. GatewayClass·Gateway는 `platform/aws/envoy-gateway/`의 AWS 전용 설정을 쓴다.

```
platform/aws/
├── up.sh / down.sh          # make aws-up / aws-down 의 본체
├── install.sh               # 클러스터 부품 설치 (terraform apply 뒤)
├── rds-init.sh + rds/init.sql
├── values/                  # Helm values: aws-load-balancer-controller, karpenter, argocd
├── karpenter/               # EC2NodeClass 1, NodePool 2 (app: 스팟 허용 / kafka: 온디맨드 + taint)
└── envoy-gateway/           # EnvoyProxy(NLB 어노테이션), AWS Gateway·CloudFront 검증 정책
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

## 실행 범위와 중단 조건

- `aws-up`은 플랫폼·NLB와 CloudFront 연결까지 준비한다. `root-aws-platform`은 `argocd/applications/platform`만 읽으며 로컬 dev/perf/demo 앱을 배포하지 않는다. AWS 전용 앱 overlay, ECR 이미지, 외부 DB/Redis/Kafka 설정, metrics-server와 실제 API 검증은 앱 배포 전에 별도로 준비한다.
- 사용자 kubeconfig·Helm 설정 대신 실행별 임시 디렉터리를 쓰고 종료 시 제거한다. Terraform의 cluster ARN과 실제 AWS 응답이 일치해야 진행한다.
- CRD 대기·조회·자원 회수 실패는 성공으로 처리하지 않는다. 부분 설치 상태에서는 누락된 부품을 복구한 뒤 다시 실행하며, 조회 실패만으로 destroy를 강행하지 않는다.
- `aws-down`은 먼저 대상 이름을 입력받는다. 별도 ArgoCD 앱·LoadBalancer·NodePool이 있으면 중단한다. `shoppinglive` Gateway의 NLB와 `app`/`kafka` NodePool 회수를 확인한 뒤 Terraform destroy 계획을 다시 확인한다.
- **개발 환경 삭제는 RDS 데이터, ECR 저장소와 이미지, 프런트 S3 파일까지 삭제한다.** 별도 bootstrap 상태 버킷만 보존된다. 필요한 데이터는 실행 전에 백업해야 한다.
- NLB 주소는 git 제외 `terraform/envs/dev/aws-runtime.auto.tfvars.json`에 기록해 다음 apply에서도 유지하며, destroy 성공 후 제거한다.
- RDS 초기화 비밀번호는 argv에 넣지 않는다. 무작위 이름의 단기 Secret/Pod를 생성하고 성공·실패 모두 자신의 자원만 제거한다.

## 자원 생성 없는 검증

`terraform init -backend=false`, `terraform validate`, mock-provider의 `command = plan` 테스트, Python/Node 회귀 테스트만 실행할 수 있다. 이 검사는 AWS 권한·할당량·실제 설치·차단 응답·비용을 입증하지 않는다. `make aws-up`, `make aws-down`, `install.sh`는 실제 환경을 변경하므로 이 검증에 포함하지 않는다.
