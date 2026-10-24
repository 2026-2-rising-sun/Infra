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

별도 상태 저장소와 기존 Route 53 호스팅 영역은 남는다. envs/dev destroy는 ECR 이미지·RDS 데이터·프런트 S3 파일도 삭제한다. 실제 비용과 잔여 자원은 실행 후 별도로 확인한다.
`envs/dev/budget.tf` 가 $50/$100/$200 에서 메일을 보낸다. 상한은 월 30만원.

## 아직 안 한 것

- **apply 는 한 번도 안 했다.** CI의 fmt·validate, 모듈 및 dev 루트 mock-provider plan 검사를 수행한다. 첫 apply 에서 리전별 제약(인스턴스 재고, 서비스 한도)이 나올 수 있다.
- `eks_version` 기본값(1.36)이 표준 지원 중인지 생성 직전에 `aws eks describe-cluster-versions` 로 확인한다.
- AWS 전용 앱 overlay·이미지와 앱 Secret(JWT 키·서비스 토큰·DB 비밀번호) 공급은 별도다. 로컬 dev/perf/demo 앱은 AWS 설치 대상에서 제외한다.
- Envoy의 `X-Origin-Verify` SecurityPolicy는 설치 코드에 연결했다. 실제 허용·거부 응답은 배포 후 검증해야 한다.
- IVS 모듈은 골격 그대로.

## CI

`.github/workflows/terraform-validate.yml`이 bootstrap·envs/*·tests 루트의 `init -backend=false`와 `validate -no-tests`, 모의 provider test를 각각 실행한다. 테스트 별칭은 test 단계에서 검증한다. AWS 자격증명이나 실제 자원은 사용하지 않는다:

```sh
terraform fmt -check -recursive terraform/
for d in terraform/bootstrap terraform/envs/dev; do terraform -chdir=$d init -backend=false && terraform -chdir=$d validate -no-tests; done
terraform -chdir=terraform/tests init -backend=false
terraform -chdir=terraform/tests test
terraform -chdir=terraform/envs/dev test
```
