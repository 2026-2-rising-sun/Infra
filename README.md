# Infra

2026-하반기프로젝트-a팀 Infra 레포지토리입니다.

라이브 커머스 서비스(`shoppinglive`)의 로컬 개발 환경, 쿠버네티스 매니페스트, 인프라 코드를 모아 둔 곳입니다.
애플리케이션 코드는 별도 레포에 있습니다 — [Backend](https://github.com/2026-2-rising-sun/Backend), [Frontend](https://github.com/2026-2-rising-sun/Frontend).

## 구조

```
Infra/
├── local/           # 로컬 개발용 Postgres/Redis/Kafka (docker compose)
├── k8s/             # kustomize base + overlays/{dev,perf,demo}
├── terraform/       # AWS 인프라 코드 (골격만)
├── argocd/          # GitOps 배포 정의 (골격만, 미적용)
├── observability/   # Prometheus/Grafana (골격만)
├── tests/           # e2e / performance (골격만, 툴 미정)
└── docs/            # 런북, 성능 측정 기록
```

각 디렉터리의 README 에 현재 상태와 결정해야 할 항목을 정리해 뒀습니다.
현재 실제로 동작하는 것은 **`local/` 과 `k8s/`** 이고, 나머지는 자리만 잡아 둔 골격입니다.

## 시작하기

```sh
cp local/.env.example local/.env     # 값 채우기
docker compose -f local/docker-compose.yml up -d
```

Postgres(5432, 서비스별 DB 5개) · Redis(6379) · Kafka(29092)가 뜹니다.
Backend 서비스는 호스트에서 직접 실행하고 여기에 붙습니다. 접속 정보는 [`local/README.md`](local/README.md) 참고.

## 서비스 진입점

별도 API 게이트웨이를 두지 않고 **k8s Ingress 의 path 라우팅**으로 5개 서비스를 하나의 엔드포인트로 묶습니다.
Frontend 는 이 엔드포인트 하나만 호출합니다.

| 경로 | 서비스 | 로컬 포트 |
|---|---|---|
| `/api/member/**` | member-service | 8081 |
| `/api/shopping/**` | shopping-service | 8082 |
| `/api/commerce/**` | commerce-service | 8083 |
| `/api/live/**` | live-service | 8084 |
| `/api/notification/**` | notification-service | 8085 |

쿠버네티스에서는 5개 서비스 모두 컨테이너 포트 **8080** 을 씁니다.
위 로컬 포트는 한 호스트에 5개를 동시에 띄울 때 충돌을 피하기 위한 것입니다. 자세한 내용은 [`k8s/README.md`](k8s/README.md).

## 매니페스트 확인

```sh
kubectl kustomize k8s/base
kubectl kustomize k8s/overlays/dev
```

PR 마다 `.github/workflows/k8s-validate.yml` 이 세 overlay 를 전부 렌더링해 확인합니다.
`terraform/` 을 건드리는 PR 은 `terraform-validate.yml` 이 `fmt -check` 와 `validate` 를 돌립니다.
