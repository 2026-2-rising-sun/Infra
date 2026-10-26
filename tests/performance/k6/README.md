# k6 부하 테스트

설계안 9장의 시나리오 4개를 k6 로 돌린다. 임계값(KEDA `lagThreshold`, live 연결 수/파드, requests)은 여기서 잰 수치로 정한다.
결과 기록은 [docs/performance/RESULTS-TEMPLATE.md](../../../docs/performance/RESULTS-TEMPLATE.md).

```
k6/
├── lib/            config(BASE_URL·사용자 수·임계값) · auth(로그인·갱신) · http(응답 봉투) · seed(시드 파일 읽기)
├── seed.mjs        테스트 사용자 N 명 · 방송 1개 · 쿠폰 1개 · 알림 신청 N 건을 만든다 (Node 22)
├── sse-holder.mjs  SSE 연결 N 개를 열어 두고 5초마다 연결 수를 찍는다 (Node 22)
├── 01-broadcast-start-surge.js      방송 시작 → 30초 안에 N 명 유입 (heartbeat·채팅·시청자 수)
├── 01-broadcast-start-surge-sse.js  위와 같되 SSE 까지 연다 (xk6-sse 로 빌드한 k6 전용)
├── 02-coupon-drop.js                N 명이 같은 순간 쿠폰 발급
├── 03-redis-failure.js              01 + 시청자 수 API 1초 탐침. 도중에 Redis 파드를 지운다
├── 04-partition-tuning.js           파티션 6 → 12 로 바꾼 뒤 01 재실행
├── 05-shopping-mixed.js             Shopping 상품 조회 혼합 부하 416 RPS (고정·단계). 아래 "시나리오 5" 참고
└── run.sh          시나리오 실행 + 결과를 Prometheus remote write 로 전송
```

## 준비

1. **k6**: https://github.com/grafana/k6/releases 에서 받는다(검증 버전 v2.3.0). `brew install k6` 도 된다.
2. **대상 환경**: kind 에 5개 서비스 + Gateway + Kafka + Redis + 관측 스택이 떠 있어야 한다(`make setup` 또는 `k8s/README.md`).
   `BASE_URL` 은 Gateway 입구다. kind 에서는 Gateway Service 를 port-forward 한 주소(`platform/kind` 문서 참고), AWS 에서는 CloudFront 도메인.
3. **Prometheus remote write**: `observability/local/deploy.py` 가 Prometheus 를 `--web.enable-remote-write-receiver` 로 띄운다. 노트북에서 k6 를 돌릴 땐 포트를 연다.
   ```sh
   kubectl -n shoppinglive-observability port-forward svc/prometheus 9090:9090
   ```
4. **시드**: 판매자 계정 `seller@local.test / seller`(local 테스트 계정)로 방송·쿠폰을 만들고 사용자 N 명을 가입시킨다. 상품이 최소 1개 있어야 쿠폰을 만들 수 있다.
   ```sh
   node tests/performance/k6/seed.mjs --base http://localhost:9080 --users 200 --limit 100
   ```
   결과 `.seed/seed.json` 에 테스트 계정 비밀번호가 있으니 커밋하지 않는다(.gitignore).

## 실행

```sh
export BASE_URL=http://localhost:9080

# 1. 방송 시작 폭주. 다른 터미널에서 SSE 연결을 같이 연다.
node tests/performance/k6/sse-holder.mjs --count 200 --ramp 30 --hold 180 &
./tests/performance/k6/run.sh 01 -e USERS=200 -e HOLD=3m

# 2. 쿠폰 드롭 (사용자 200, 한도 100 이면 101번째부터 4xx 가 나와야 한다)
./tests/performance/k6/run.sh 02 -e USERS=200

# 3. Redis 장애. 부하 중에 다른 터미널에서:
#    kubectl -n shoppinglive-dev delete pod -l app.kubernetes.io/name=redis
./tests/performance/k6/run.sh 03 -e USERS=200

# 4. 파티션 튜닝. KafkaTopic partitions 와 notification maxReplicaCount 를 바꾼 뒤:
./tests/performance/k6/run.sh 04 -e USERS=200 -e PARTITIONS=12
```

`run.sh` 는 `testid` 태그를 붙이고 요약을 `.results/<testid>.json` 에 남긴다. Grafana **06 · 부하 테스트** 대시보드에서 같은 testid 를 고르면 k6 요청률·p95 와 파드 수·컨슈머 랙·SSE 연결 수가 한 화면에 나온다.

시나리오 1·3·4 는 **같은 방송**을 다시 시작한다. 방송이 이미 시작된 상태면 `start` 가 409 를 돌려주는데, 그래도 진행한다(랙 급증은 첫 시작 때만 난다). 랙 해소 시간을 다시 재려면 `seed.mjs` 를 다시 돌려 새 방송을 만든다.

## 환경변수

| 이름 | 기본값 | 뜻 |
|---|---|---|
| `BASE_URL` | `http://localhost:9080` | Gateway 입구 |
| `USERS` | 50 | 동시 시청자(VU) 수 = 알림 신청자 수와 맞추는 게 자연스럽다 |
| `RAMP` / `HOLD` | 30s / 3m | 유입 시간 / 유지 시간 |
| `HEARTBEAT_INTERVAL` | 15 | 초. Frontend 와 같은 값 |
| `CHAT_EVERY` | 4 | heartbeat 몇 번마다 채팅 1건 |
| `CLICKS` (02) | 2 | 사용자당 클릭 수. 2번째는 "이미 보유" 응답 확인용 |
| `PARTITIONS` (04) | unset | 결과 태그용 |
| `SEED_FILE` | `../.seed/seed.json` | 시드 파일. 상대 경로는 `lib/` 기준이라 바꿀 땐 절대 경로로 준다 |

## 시나리오 5: Shopping 상품 조회 혼합 부하

방송 1개 시청자 3,000명일 때 Shopping 파드 1개가 받는 요청을 Infra #49 표의 비율로 보낸다.

| API | 요청/초 | 경로 |
|---|---|---|
| 상세 | 99 | Gateway `/api/shopping/v1/products/{id}` |
| 상품 쿠폰 | 90 | Gateway `/api/shopping/v1/products/{id}/coupons` |
| 구매 사전 확인 | 9 | Gateway `/api/shopping/v1/products/{id}/purchase-check?quantity=1` |
| Live 묶음 조회 (10개) | 200 | Shopping 직접 `/v1/internal/products?ids=…` |
| Commerce 단건 조회 | 18 | Shopping 직접 `/v1/internal/products/{id}` |

판정은 p99 ≤ 300ms, 오류율 < 1%, dropped iterations 0 이다. 하나라도 넘으면 k6 가 0 이 아닌 코드로 끝난다.

### 준비

1. 판매 중 상품 1,000개와 앞 100개 상품에 붙는 쿠폰 1개를 만든다. 결과는 `.seed/products.json`. 실행할 때마다 새 상품을 만든다.
   ```sh
   node tests/performance/k6/seed.mjs --base http://localhost:9080 --products 1000 --coupon-products 100
   ```
   쿠폰은 Kafka 로 Shopping 에 동기화된다. 실행 전 `curl $BASE_URL/api/shopping/v1/products/<첫 상품 ID>/coupons` 로 쿠폰이 보이는지 확인한다.
2. 내부 API 는 Gateway 에 없다. Shopping Service 를 따로 port-forward 한다.
   ```sh
   kubectl -n shoppinglive-dev port-forward svc/shopping-service 8081:8080
   ```
3. 서비스 토큰을 Secret 에서 읽어 환경변수로만 넘긴다. 파일·저장소에 쓰지 않는다. Live 용 토큰은 묶음·단건 조회를 모두 허용한다.
   ```sh
   export SERVICE_TOKEN=$(kubectl -n shoppinglive-dev get secret live-shopping-service-token -o jsonpath='{.data.token}' | base64 -d)
   ```

### 실행

```sh
export BASE_URL=http://localhost:9080 SHOPPING_URL=http://localhost:8081

# 고정 부하: 416 RPS × 5분
./tests/performance/k6/run.sh 05

# 단계 부하: 416 RPS 의 0.5·1·1.5·2·3·4 배를 1분씩. 처음 실패한 단계와 원인을 출력한다
./tests/performance/k6/run.sh 05 -e MODE=step

# 상품 1개 집중: 상세·쿠폰·구매 확인·단건은 첫 상품, 묶음은 앞 10개만 조회한다
./tests/performance/k6/run.sh 05 -e FOCUS=1
```

| 이름 | 기본값 | 뜻 |
|---|---|---|
| `MODE` | `fixed` | `fixed` 또는 `step` |
| `SCALE` / `DURATION` | 1 / `5m` | 고정 부하의 배수와 시간 |
| `STEPS` / `STEP_DURATION` | `0.5,1,1.5,2,3,4` / `1m` | 단계 부하의 배수 목록과 단계별 시간 |
| `FOCUS` | unset | `1` 이면 상품 1개 집중 |
| `SHOPPING_URL` | `http://localhost:8081` | 내부 API 를 받을 Shopping Service 주소 |
| `SERVICE_TOKEN` | 없음(필수) | `X-Service-Token` 값 |
| `PRODUCTS_FILE` | `./.seed/products.json` | 상품 시드. 상대 경로는 시나리오 파일 기준 |

### 결과 확인

- 터미널: 끝나면 API 별 목표·실제 요청률·차이(±5% 안이어야 한다)·p99 와, 단계별 요청률·p99·오류율·dropped·판정, 처음 실패한 단계를 출력한다.
- 파일: `.results/<testid>.json` 에 단계(`step`)·API(`api`) 태그별 지표가 남는다.
- Grafana: **06 · 부하 테스트** 대시보드에서 testid 를 고른다. 요청에는 `api`, `step`, `name` 태그가 붙는다. 같은 시간의 Shopping 파드 CPU·메모리를 함께 본다.

## SSE 를 k6 안에서 열려면 (선택)

기본 k6 는 SSE 를 못 열어서 `sse-holder.mjs` 를 옆에서 돌린다. k6 하나로 다 하려면 [xk6-sse](https://github.com/phymbert/xk6-sse) 로 빌드한다.

```sh
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/xk6" grafana/xk6 build --with github.com/phymbert/xk6-sse
./k6 run tests/performance/k6/01-broadcast-start-surge-sse.js -e BASE_URL=$BASE_URL -e USERS=200
```

## 임계값

`lib/config.js` 의 기본 임계값은 설계안 알림 규칙과 같다: 실패율 5% 미만, p99 1초 미만. 시나리오 3 은 장애 실험이라 느슨하다(실패율 20%, p99 2초, 503 구간 60초 미만). 임계값을 넘으면 k6 가 0 이 아닌 코드로 끝난다.

## 어디서 돌리나

- 로컬 kind: 노트북에서. 파드 수 변화·랙 해소·에러율은 볼 수 있지만 노드가 고정이라 Karpenter 는 못 본다. 노트북 자체가 병목이 되면 USERS 를 낮춘다.
- AWS: 클러스터 밖 EC2 1대에서 CloudFront 를 거쳐 돌린다. 같은 스크립트에 `BASE_URL` 만 바꾼다.

쿠폰 드롭은 200·201 및 계약의 409 CONFLICT만 허용한다. 이미 발급받은 VU의 재요청은 200이어야 하며, 201 합계가 시드의 `couponLimit`을 넘으면 실패한다. 409는 기간 오류와 수량 소진을 구분하지 않으므로 유효 기간 안의 새 시드를 사용해야 한다.
