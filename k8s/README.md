# k8s

Kubernetes 매니페스트. kustomize base + overlay 구조.

```
k8s/
├── base/
│   ├── {member,shopping,commerce,live,notification}-service/
│   │   └── {deployment.yaml,service.yaml,kustomization.yaml}
│   ├── gateway/              # 단일 진입점: Gateway + 서비스별 HTTPRoute (path 라우팅)
│   └── kustomization.yaml
├── overlays/
│   ├── dev/
│   │   ├── kustomization.yaml    # services + datatier 를 묶는다
│   │   ├── services/             # base + namePrefix(dev-) + replica/리소스/프로필 patch
│   │   ├── datatier/             # dev 전용 Postgres/Redis/Kafka
│   │   └── tools/                # Kafka UI, Redis Insight (수동 적용, ArgoCD 동기화 대상 아님)
│   └── {perf,demo}/kustomization.yaml
└── local/                        # 로컬 kind 클러스터 전용 (Dashboard 계정, port-forward 스크립트)
```

## 진입점

별도 API 게이트웨이 서비스를 두지 않는다. `base/gateway/` 의 Gateway API 리소스가 경로로 서비스를 가른다.
입구(`gateway.yaml`, 포트·호스트)와 경로 규칙(`httproute-<service>.yaml`, 서비스마다 하나)을 나눠 둔다.

| 경로 | 서비스 |
|---|---|
| `/api/member/**` | `member-service:8080` |
| `/api/shopping/**` | `shopping-service:8080` |
| `/api/commerce/**` | `commerce-service:8080` |
| `/api/live/**` | `live-service:8080` |
| `/api/notification/**` | `notification-service:8080` |

Frontend 는 이 Gateway 엔드포인트 하나만 호출한다.
경로 prefix 는 백엔드로 넘길 때 제거된다 — `/api/member/v1/users/1` → member-service 는 `/v1/users/1` 로 받는다.
접두사 제거는 HTTPRoute 표준 필터(`URLRewrite`)라 다른 Gateway API 구현체로 바꿔도 YAML 이 그대로다.
live 만 라우트 요청 타임아웃을 끈다(`timeouts.request: 0s`). SSE 응답이 방송 내내 열려 있기 때문이다.

**전제: 클러스터에 Gateway API CRD 와 Envoy Gateway 컨트롤러(GatewayClass `envoy-gateway`)가 있어야 한다.**
로컬은 `platform/kind/install.sh` 가 설치한다. 이전의 ingress-nginx 는 2026-03 에 은퇴해(보안 패치 없음) 더 쓰지 않는다.
overlay 가 `namePrefix` 를 붙이면 HTTPRoute 가 가리키는 Service·Gateway 이름도 따라가야 하는데 kustomize 는 Gateway API 를 모른다.
`base/gateway/kustomizeconfig.yaml` 이 그 참조 경로를 알려 준다(렌더링 결과에서 `dev-member-service` 처럼 바뀌는지 확인).

## 포트

컨테이너 포트는 5개 서비스 모두 **8080** 으로 통일한다.
서비스별 포트(member 8081 … notification 8085)는 **로컬에서 5개를 한 호스트에 동시에 띄울 때만** 쓴다.
5개 서비스의 health probe와 Prometheus 수집은 별도 관리 포트 **9090**을 사용한다.
Service·HTTPRoute에는 8080만 연결한다. 필수 JWKS·개인키·호출 토큰·TTL 입력은 [P2 Infra 가이드](https://app.notion.com/p/3ec226545d15811087c4c552be01e341)를 따른다.

## 환경별 차이

`base`는 환경 공통 포트·보안 리소스 참조를 정의한다. overlay는 replica·리소스·프로필을 바꾸며, 참조하는 키와 토큰은 namespace마다 별도로 공급한다.

| overlay | namespace | prefix | replicas | 성격 |
|---|---|---|---|---|
| `dev` | `shoppinglive-dev` | `dev-` | 1 | 기능 확인용 최소 구성 |
| `perf` | `shoppinglive-perf` | `perf-` | 2 | 부하 테스트, 추후 HPA 부착 |
| `demo` | `shoppinglive-demo` | `demo-` | 2 | 시연용 고정 |

## dev 의 미들웨어 (`overlays/dev/datatier/`)

dev 에는 Postgres/Redis 를 네임스페이스 안에 단일 pod 로, Kafka 는 Strimzi CR(Kafka/KafkaNodePool/KafkaTopic)로 띄운다.
Strimzi 오퍼레이터가 CR 을 읽어 브로커 파드와 토픽을 만든다(설치는 `platform/kind/install.sh`).
토픽 4개와 파티션 수를 YAML 로 선언하므로 부하 테스트에서 파티션을 바꾸는 실험을 apply 한 번으로 한다. AWS 에서도 같은 CR 을 쓴다.

| 리소스 | 이미지 | Service | 볼륨 |
|---|---|---|---|
| Postgres | `postgres:16-alpine` | `postgres:5432` | `emptyDir` |
| Redis | `redis:7-alpine` | `redis:6379` | 없음 |
| Kafka (Strimzi, KRaft, 노드 풀 `dual` 1개) | 오퍼레이터 기본 Kafka 이미지 | `kafka-kafka-bootstrap:9092` (별칭 `kafka:9092`) | `ephemeral` |

- Postgres 는 ConfigMap 으로 붙인 init 스크립트가 서비스별 DB 5개(`member`, `shopping`, `commerce`, `live`, `notification`)를 만든다. `local/init/postgres/01-create-databases.sh` 와 같은 로직이다.
- 자격증명은 `datatier/postgres.yaml` 의 Secret 에 있다. **dev 전용 폐기 가능한 값**이라 레포에 그대로 둔다. 다른 환경에서는 외부 시크릿 관리로 주입한다.
- 어느 것도 데이터를 보존하지 않는다. pod 가 다시 뜨면 DB 는 init 스크립트로, Kafka 토픽은 KafkaTopic CR(DLT 는 auto-create)로 복구된다.
- Service 이름 `kafka` 는 이전 Deployment 시절 이름을 쓰는 곳(Backend dev 프로필 기본값, Kafka UI, 관측 exporter)을 위한 별칭이다. 서비스 Deployment 는 env `SPRING_KAFKA_BOOTSTRAP_SERVERS=kafka-kafka-bootstrap:9092` 로 붙는다.
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

`.github/workflows/k8s-validate.yml` 이 PR 마다 세 overlay 와 `dev/tools` 를 렌더링해 본다.

## 로컬 kind 클러스터에서 dev 띄우기

공유 dev 환경에 올리기 전에 서비스 5개와 미들웨어를 한 번에 띄워 보는 절차다.
서비스 이미지는 Backend CI 가 GHCR 에 올린 `:latest` 를 받는다(amd64/arm64 멀티아키텍처).

**준비물**: Docker Desktop, `kubectl`, `kind`, `helm` (`brew install kind helm`)

### 1. 클러스터와 대시보드

```sh
kind create cluster --name shoppinglive-dev --config platform/kind/kind-config.yaml   # Gateway 포트(9080) 매핑 포함

kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml
kubectl apply -f k8s/local/dashboard-admin.yaml
kubectl -n kubernetes-dashboard create token admin-user --duration=24h   # 로그인 토큰
```

### 1-1. 플랫폼 (Gateway API CRD, Envoy Gateway, Strimzi)

앱 매니페스트가 참조하는 CRD 와 컨트롤러를 먼저 넣는다. 멱등이라 다시 실행해도 된다.

```sh
./platform/kind/install.sh               # KUBE_CONTEXT 기본값 kind-shoppinglive-dev
```

### 2. 배포

미들웨어를 먼저 올리고 준비된 뒤 서비스를 올린다. 한 번에 올리면 서비스가 Postgres 보다 먼저 떠서
`Connection refused` 로 몇 번 재시작하고, 재시작 대기 시간(CrashLoopBackOff)이 점점 길어진다.
P2 이미지를 적용하기 전에는 [필수 보안 리소스](https://app.notion.com/p/3ec226545d15811087c4c552be01e341)를 같은 namespace에 먼저 공급해야 한다.
kind에서는 `k8s/local/auth-secrets.sh`가 JWT 키·JWKS·kid와 서비스 간 토큰 8개를 만든다(이미 있으면 건너뜀). 운영 환경 키를 만드는 용도는 아니다.

```sh
NS=shoppinglive-dev
sh k8s/local/auth-secrets.sh $NS                       # 인증 키·서비스 토큰 (최초 1회)
kubectl apply -k k8s/overlays/dev                      # 전체 적용 (네임스페이스 포함)
for d in postgres redis; do kubectl rollout status deploy/$d -n $NS --timeout=10m; done
kubectl wait kafka/kafka -n $NS --for=condition=Ready --timeout=10m   # Strimzi 가 브로커·토픽을 만들 때까지

# 미들웨어 준비 후 서비스만 재시작한다. 라벨(part-of=shoppinglive)은 미들웨어에도 붙어 있어서
# 라벨로 고르면 Postgres 까지 재시작되니 이름으로 지정한다.
# (목록을 변수에 담지 않는다. zsh 는 따옴표 없는 변수를 단어로 나누지 않는다.)
kubectl rollout restart -n $NS deploy/dev-member-service deploy/dev-shopping-service \
  deploy/dev-commerce-service deploy/dev-live-service deploy/dev-notification-service
for d in member shopping commerce live notification; do
  kubectl rollout status deploy/dev-$d-service -n $NS --timeout=5m
done
kubectl get pods -n $NS                                # 전부 1/1 Running 이면 정상

kubectl apply -k k8s/overlays/dev/tools                # 선택: Kafka UI, Redis Insight
```

### 3. 접속

```sh
./k8s/local/port-forward-dev.sh          # 아래 포트를 한 번에 연결, Ctrl+C 로 종료
kubectl proxy                            # 대시보드용, 다른 터미널에서
```

| 대상 | 주소 |
|---|---|
| API 진입점 (Gateway) | http://localhost:9080/api/<service>/... — Frontend 가 쓰는 경로. `kind-config.yaml` 로 만든 클러스터는 port-forward 없이도 열려 있다 |
| 서비스 API | http://localhost:9081 (member) … 9085 (notification); health·prometheus는 별도 9090 |
| Kubernetes Dashboard | http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/ |
| Kafka UI | http://localhost:28080 |
| Redis Insight | http://localhost:25540 (처음 한 번 Host `redis`, Port `6379` 로 등록) |
| Postgres | `localhost:25432`, 계정 `shoppinglive` / `changeme` |
| Redis | `localhost:26379` |

- 서비스는 IntelliJ 로컬 실행 포트(8081~8085)와 겹치지 않게 9081~9085 를 쓴다.
- Postgres/Redis 는 `local/docker-compose.yml` 과 동시에 켜 둘 수 있게 25432/26379 를 쓴다.
- Kafka 브로커는 호스트로 연결하지 않는다. 브로커가 자기 주소를 `kafka:9092` 로 광고해서 호스트 클라이언트는
  부트스트랩 이후 접속하지 못한다. Kafka UI 를 쓰거나 `kubectl exec -n shoppinglive-dev kafka-dual-0 -- /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list` 로 확인한다.

### 4. 정리

```sh
kubectl delete -k k8s/overlays/dev/tools
kubectl delete -k k8s/overlays/dev
kind delete cluster --name shoppinglive-dev   # 클러스터째 삭제
```

## 이미지 태그

지금은 `ghcr.io/2026-2-rising-sun/<service>:latest` placeholder다.
Backend CI 가 이미지를 푸시하기 시작하면 커밋 SHA 기반 고정 태그로 바꾼다 (`argocd/README.md` 참고).
