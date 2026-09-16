# k8s

Kubernetes 매니페스트. kustomize base + overlay 구조.

```
k8s/
├── base/
│   ├── {member,shopping,commerce,live,notification}-service/
│   │   └── {deployment.yaml,service.yaml,kustomization.yaml}
│   ├── ingress.yaml          # 5개 서비스의 단일 진입점 (path 라우팅)
│   └── kustomization.yaml
└── overlays/
    ├── dev/
    │   ├── kustomization.yaml    # services + datatier 를 묶는다
    │   ├── services/             # base + namePrefix(dev-) + replica/리소스/프로필 patch
    │   └── datatier/             # dev 전용 Postgres/Redis/Kafka
    └── {perf,demo}/kustomization.yaml
```

## 진입점

별도 API 게이트웨이 서비스를 두지 않는다. `base/ingress.yaml` 이 경로로 서비스를 가른다.

| 경로 | 서비스 |
|---|---|
| `/api/member/**` | `member-service:8080` |
| `/api/shopping/**` | `shopping-service:8080` |
| `/api/commerce/**` | `commerce-service:8080` |
| `/api/live/**` | `live-service:8080` |
| `/api/notification/**` | `notification-service:8080` |

Frontend 는 이 Ingress 엔드포인트 하나만 호출한다.
경로 prefix 는 백엔드로 넘길 때 제거된다 — `/api/member/v1/users/1` → member-service 는 `/v1/users/1` 로 받는다.

**전제: 클러스터에 ingress-nginx 컨트롤러가 있어야 한다.** `rewrite-target` 과 정규식 캡처 그룹은 ingress-nginx 전용 문법이다.

## 포트

컨테이너 포트는 5개 서비스 모두 **8080** 으로 통일한다.
서비스별 포트(member 8081 … notification 8085)는 **로컬에서 5개를 한 호스트에 동시에 띄울 때만** 쓴다.

## 환경별 차이

`base` 는 환경 공통이고, 차이는 overlay 의 patch 로만 표현한다. 현재는 replica 수, 리소스 값, `SPRING_PROFILES_ACTIVE` 세 가지뿐이다.

| overlay | namespace | prefix | replicas | 성격 |
|---|---|---|---|---|
| `dev` | `shoppinglive-dev` | `dev-` | 1 | 기능 확인용 최소 구성 |
| `perf` | `shoppinglive-perf` | `perf-` | 2 | 부하 테스트, 추후 HPA 부착 |
| `demo` | `shoppinglive-demo` | `demo-` | 2 | 시연용 고정 |

## dev 의 미들웨어 (`overlays/dev/datatier/`)

dev 에는 `local/docker-compose.yml` 과 같은 구성의 Postgres/Redis/Kafka 를 네임스페이스 안에 단일 pod 로 띄운다.
관리형 서비스(RDS 등)나 Strimzi 같은 오퍼레이터는 팀 규모가 커지면 그때 검토한다.

| 리소스 | 이미지 | Service | 볼륨 |
|---|---|---|---|
| Postgres | `postgres:16-alpine` | `postgres:5432` | `emptyDir` |
| Redis | `redis:7-alpine` | `redis:6379` | 없음 |
| Kafka (단일 브로커 KRaft) | `apache/kafka:4.0.0` | `kafka:9092` | `emptyDir` |

- Postgres 는 ConfigMap 으로 붙인 init 스크립트가 서비스별 DB 5개(`member`, `shopping`, `commerce`, `live`, `notification`)를 만든다. `local/init/postgres/01-create-databases.sh` 와 같은 로직이다.
- 자격증명은 `datatier/postgres.yaml` 의 Secret 에 있다. **dev 전용 폐기 가능한 값**이라 레포에 그대로 둔다. 다른 환경에서는 외부 시크릿 관리로 주입한다.
- 어느 것도 데이터를 보존하지 않는다. pod 가 다시 뜨면 DB 는 init 스크립트로, Kafka 토픽은 auto-create 로 복구된다.
- `datatier` 에는 `namePrefix` 를 붙이지 않는다. Backend 의 `dev` 프로필이 Service 이름(`postgres`/`redis`/`kafka`)으로 접속하므로 overlay 의 prefix 규약이 애플리케이션 설정으로 새어 나가지 않게 한다. 계층을 나눈 또 다른 이유는 `services` 의 `kind: Deployment` patch 가 미들웨어 Deployment 까지 잡아 `env[0]` 을 덮어쓰기 때문이다.
- `perf`/`demo` 는 나중에 다른 방식으로 갈 수 있어 `base` 가 아니라 dev overlay 에만 뒀다.

overlay 의 patch 는 JSON 6902 로 `containers/0` 을 지정한다.
컨테이너 이름이 서비스마다 달라 strategic merge 로는 한 번에 못 고치기 때문이다.
모든 Deployment 가 컨테이너 1개짜리 같은 모양이라는 전제가 깨지면 patch 를 서비스별로 나눠야 한다.

## 확인

```sh
kubectl kustomize k8s/base
kubectl kustomize k8s/overlays/dev
```

`.github/workflows/k8s-validate.yml` 이 PR 마다 세 overlay 를 전부 렌더링해 본다.

## 이미지 태그

지금은 `ghcr.io/2026-2-rising-sun/<service>:latest` placeholder다.
Backend CI 가 이미지를 푸시하기 시작하면 커밋 SHA 기반 고정 태그로 바꾼다 (`argocd/README.md` 참고).
