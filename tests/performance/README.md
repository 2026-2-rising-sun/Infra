# tests/performance

**도구: k6.** 시나리오와 실행 방법은 [k6/README.md](k6/README.md), 결과 기록은 `docs/performance/`.

k6 를 고른 이유: 시나리오가 JavaScript 라 API 계약을 그대로 옮길 수 있고, 결과를 Prometheus remote write 로 보내
이미 있는 Grafana(로컬 관측 스택)에서 파드 수·컨슈머 랙과 같은 화면에 놓을 수 있다. Gatling/Locust 는 JVM·Python 런타임과
별도 결과 저장소가 필요해 제외했다.

시나리오(설계안 9장)
1. 방송 시작 폭주 — notification 랙 해소 시간, live 파드·SSE 연결 수, p99
2. 선착순 쿠폰 드롭 — commerce p99, DB 커넥션, 중복 발급 0건
3. Redis 장애 — 시청자 수 API 503 지속 시간, SSE 끊김·복구
4. 파티션 튜닝 — 파티션 6 → 12 뒤 1번 재실행, 랙 해소 시간 비교

목표치(SLO)는 아직 정하지 않았다. 설계안 알림 규칙(실패율 5%, p99 1초)을 출발 임계값으로 두고 기준선 측정 뒤 확정한다.
