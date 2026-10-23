# terraform

AWS 인프라 코드. 설계안 5장의 모듈을 `envs/dev` 루트에서 잇는다. **원칙: 필요할 때만 만들고, 끝나면 지운다.**

```
terraform/
├── bootstrap/            # 상태 저장소(S3 + DynamoDB). 계정당 한 번 apply, 지우지 않는다
├── envs/dev/             # 루트 모듈. main.tf 가 아래 모듈을 잇는다
│   ├── backend.hcl.example       # S3 백엔드 설정 (복사해 채움, git 제외)
│   └── terraform.tfvars.example  # 도메인·비밀값 (복사해 채움, git 제외)
└── modules/
    ├── network    VPC, 서브넷 2 AZ, NAT 1
    ├── eks        클러스터, 시스템 노드 2대(arm64), Pod Identity, 애드온 5개
    ├── karpenter  노드 IAM, 컨트롤러 IAM, 스팟 중단 큐
    ├── nlb        로드밸런서 컨트롤러 IAM, CloudFront 전용 보안그룹 (NLB 자체는 클러스터가 만든다)
    ├── rds        PostgreSQL db.t4g.small 1대, 비밀번호는 Secrets Manager
    ├── edge       S3+OAC, CloudFront, WAF, ACM 2장, Route 53
    ├── ecr        이미지 저장소 5개
    ├── ci         GitHub Actions OIDC 역할
    └── ivs        (골격 유지, 범위 밖)
```

## 처음 한 번

```sh
aws configure                      # 정 개인 계정. 루트가 아닌 IAM 사용자/SSO
make aws-bootstrap                 # 상태 저장소
cd terraform/envs/dev
cp backend.hcl.example backend.hcl && cp terraform.tfvars.example terraform.tfvars
# backend.hcl: bootstrap output 의 bucket. tfvars: 도메인, 호스팅 영역, origin_verify_secret, 메일
```

## 올리고 내리기

```sh
make aws-up      # terraform apply → platform/aws/install.sh → NLB 주소로 두 번째 apply. 약 30분
make aws-down    # LoadBalancer Service·NodePool 삭제 → destroy. 약 15분
```

`aws-down` 이 쿠버네티스 쪽부터 지우는 이유: NLB 와 Karpenter 노드는 클러스터 안 컨트롤러가 만든 것이라 `terraform destroy` 가 모른다. 그냥 destroy 하면 VPC 삭제가 막히거나, 더 나쁘게는 NLB·EC2 가 남아 과금된다.

## 비용 (서울, 2026-10 목록가 기준 대략)

| 켜져 있을 때 | 시간당 | 비고 |
|---|---|---|
| EKS 컨트롤 플레인 | $0.10 | 표준 지원 버전일 때. 연장 지원이면 $0.60 |
| 시스템 노드 t4g.medium × 2 | $0.08 | |
| NAT 게이트웨이 1 | $0.059 + 전송 | |
| RDS db.t4g.small | $0.04 | |
| NLB | $0.03 + LCU | |
| 앱 노드 (Karpenter) | m7g.large 스팟 ≈ $0.03/대 | 부하에 따라 0~4대 |
| **합계** | **≈ $0.35 고정 + 노드** | 하루 8시간 × 20일 ≈ $60~110/월 |

항상 남는 것: 상태 저장소·ECR 이미지(월 $1 미만), Route 53 호스팅 영역($0.50/월). CloudFront·WAF·S3 는 요청량 과금이라 안 쓰면 거의 0.
`envs/dev/budget.tf` 가 $50/$100/$200 에서 메일을 보낸다. 상한은 월 30만원.

## 아직 안 한 것

- **apply 는 한 번도 안 했다.** CI 의 `fmt -check` + `validate` 만 통과한 상태다. 첫 apply 에서 리전별 제약(인스턴스 재고, 서비스 한도)이 나올 수 있다.
- `eks_version` 기본값(1.36)이 표준 지원 중인지 생성 직전에 `aws eks describe-cluster-versions` 로 확인한다.
- 앱 Secret(JWT 키·서비스 토큰·DB 비밀번호)을 Secrets Manager → External Secrets 로 공급하는 것은 후속. 지금은 `k8s/local/auth-secrets.sh` 를 EKS 컨텍스트에서 돌린다.
- Envoy 의 `X-Origin-Verify` 헤더 검사는 후속. 1차 방어(NLB 보안그룹 = CloudFront IP 만)는 돼 있다.
- IVS 모듈은 골격 그대로.

## CI

`.github/workflows/terraform-validate.yml` 이 PR 마다 `fmt -check` 와 루트별 `init -backend=false` + `validate` 를 돌린다. `bootstrap` 도 루트지만 `envs/*` 글롭 밖이라 CI 에 안 잡힌다. 로컬에서 같이 돌린다:

```sh
terraform fmt -check -recursive terraform/
for d in terraform/bootstrap terraform/envs/dev; do terraform -chdir=$d init -backend=false && terraform -chdir=$d validate; done
```
