# 오토스케일링(KEDA) 확인 절차

dev overlay 의 파드 수는 `k8s/overlays/dev/scaling/` 의 ScaledObject 가 정한다. 이 문서는 "지금 왜 이 파드 수인지"를 보고, 일부러 부하를 만들어 늘어나는지 확인하는 절차다. 수치는 설계 출발값이고 부하 테스트(`tests/performance`)로 확정한다.

## 무엇이 무엇을 늘리나

| 서비스 | 신호 | 파드 1개가 감당하는 양 | 최소~최대 |
|---|---|---|---|
| notification | `live.broadcast.v1` 컨슈머 랙 | 랙 100 | 1~6 (파티션 6) |
| shopping | `commerce.coupon-info.v1`·`sales-info.v1` 랙 + CPU | 랙 100, CPU 70% | 1~1 (이미지 S3 전환 전까지) |
| live | 열린 SSE 연결 수 + 10분 내 시작 방송의 알림 신청자 수 | 연결 500, 신청자 1,000 | 1~8 |
| member | CPU | 70% | 2~6 |
| commerce | CPU | 70% | 1~6 |

KEDA 는 ScaledObject 하나당 HPA 하나를 만든다. 트리거가 여럿이면 각각이 원하는 파드 수 중 **가장 큰 값**을 쓴다. 늘릴 때는 15초마다 최대 4개(서비스별 차이 있음), 줄일 때는 5분 동안 최고치를 유지한 뒤 1분에 1개씩 줄인다.

## 상태 보기

```sh
NS=shoppinglive-dev
kubectl -n $NS get scaledobject            # READY/ACTIVE, 트리거 종류, 최소/최대
kubectl -n $NS get hpa                     # TARGETS 열에 "현재값/임계값", REPLICAS 가 지금 파드 수
kubectl -n $NS describe scaledobject dev-live-service | tail -20   # 조건과 최근 이벤트
kubectl -n keda logs deploy/keda-operator --since=5m | grep -i -E "error|fail"
```

`READY=False` 면 대개 트리거 대상을 못 찾은 것이다. 자주 나오는 원인:
- Kafka: `kafka-kafka-bootstrap.shoppinglive-dev:9092` 에 못 붙음 → Strimzi Kafka 가 Ready 인지 확인.
- Kafka: 컨슈머 그룹이 아직 없음(서비스가 한 번도 메시지를 읽지 않음) → 랙 0 으로 취급되며 정상.
- Prometheus: `prometheus.shoppinglive-observability:9090` 응답 없음 → `observability/local/deploy.py --apply` 했는지 확인.
- Prometheus: 지표 이름이 없음 → Backend 가 observability 프로필로 떠 있고 `shoppinglive_live_sse_connections` 가 `/actuator/prometheus` 에 있는지 확인.

HPA 의 TARGETS 가 `<unknown>` 이면 지표 서버(`keda-operator-metrics-apiserver`)가 값을 못 주는 것이다. `kubectl get apiservice v1beta1.external.metrics.k8s.io` 가 `True` 인지 본다.

## 일부러 늘려 보기

### notification — 랙 만들기

Strimzi 가 띄운 브로커 파드 안의 도구로 `live.broadcast.v1` 에 메시지를 쏟는다. notification 이 소비하는 속도보다 빠르게 넣으면 랙이 쌓인다.

```sh
kubectl -n $NS run kafka-load --rm -it --restart=Never \
  --image=quay.io/strimzi/kafka:latest-kafka-4.0.0 -- \
  bin/kafka-producer-perf-test.sh --topic live.broadcast.v1 --num-records 20000 \
  --record-size 512 --throughput 2000 --producer-props bootstrap.servers=kafka-kafka-bootstrap:9092
```

메시지 본문이 이벤트 계약과 다르면 notification 이 역직렬화 실패로 처리를 건너뛸 수 있다. 그래도 **랙 자체는 생기므로** 스케일링 확인에는 쓸 수 있다. 실제 계약대로 보내려면 `tests/performance` 의 시나리오를 쓴다.

예상 흐름: 15초 안에 HPA TARGETS 의 랙 값이 오름 → 다음 주기에 `REPLICAS` 증가(최대 4개/15초) → 새 파드 Ready 까지 20~40초 → 랙 해소 → 5분 뒤부터 1분에 1개씩 감소.

### live — 연결 수 또는 신청자 수 올리기

실제 SSE 연결은 `tests/performance` 의 연결 유지 스크립트로 N개를 열어 둔다. 지표만 흉내 내려면 Prometheus 쿼리를 Grafana Explore 에서 먼저 확인한다.

```promql
sum(shoppinglive_live_sse_connections{namespace="shoppinglive-dev",service="live-service"})
max(shoppinglive_broadcast_upcoming_alert_subscribers{namespace="shoppinglive-dev",service="notification-service"})
```

이 두 값 / 임계값(500, 1000)의 올림이 HPA 가 원하는 파드 수다. 선제 확장은 방송 `scheduledAt` 10분 전부터 값이 생기므로, 알림 신청자가 있는 방송을 10분 뒤로 예약해 두면 확인할 수 있다.

### member·commerce — CPU

k6 로 로그인 또는 쿠폰 발급을 반복 호출한다. dev 의 requests 는 50m 라 금방 70% 를 넘는다.

## 되돌리기

ScaledObject 를 지우면 KEDA 가 HPA 도 지우고, 파드 수는 그 시점 값으로 멈춘다. 고정하려면 `kubectl scale` 로 맞춘다.

```sh
kubectl -n $NS delete scaledobject dev-live-service
kubectl -n $NS scale deploy/dev-live-service --replicas=1
```

## 파드 수가 줄지 않을 때

- 5분 안정화 창이 아직 안 지났다. `kubectl -n $NS describe hpa` 의 이벤트 시각을 본다.
- 트리거 중 하나가 아직 높다(예: 연결 수는 0 인데 신청자 지표가 남아 있음). HPA 는 최댓값을 쓴다.
- PDB(`member`, `live` 는 `minAvailable: 1`)는 자발적 퇴거만 막고 HPA 축소는 막지 않는다. 노드가 안 줄어드는 것은 PDB 쪽 문제다.
