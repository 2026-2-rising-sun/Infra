# terraform

**상태: 골격만.** `envs/dev` 에 provider/backend 설정과 TODO 주석만 있고, 실제 AWS 리소스는 정의하지 않았다.

팀이 AWS 사용 범위(계정, 리전, 비용 한도)를 합의한 뒤 `modules/` 를 하나씩 채운다.

```
terraform/
├── envs/dev/{main.tf,variables.tf,backend.tf}
└── modules/{network,eks,rds,ivs}/   # 각 README 에 결정해야 할 항목 정리
```

## 상태 파일

지금은 로컬 백엔드(`backend.tf`)라 여럿이 동시에 쓸 수 없다.
AWS 계정이 생기면 S3 + DynamoDB 잠금으로 옮긴다 (`backend.tf` 주석 참고).
**그 전까지는 `terraform apply` 를 실행하지 않는다.**

## CI

`.github/workflows/terraform-validate.yml` 이 PR 마다 `terraform fmt -check` 와 `terraform validate` 를 돌린다.
`validate` 는 AWS 자격증명 없이 동작하며, 아무것도 생성하지 않는다.
