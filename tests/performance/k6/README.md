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
