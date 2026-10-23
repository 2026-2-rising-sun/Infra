# 부하 테스트 기록 템플릿

측정 1건마다 이 파일을 복사해 `docs/performance/YYYY-MM-DD-<시나리오>.md` 로 남긴다.
수치만 있고 조건이 없으면 나중에 비교가 안 되므로 위쪽 조건 표를 먼저 채운다.

## 조건

| 항목 | 값 |
|---|---|
| 측정 일시 | |
| Backend / Infra 커밋 | `sha` / `sha` |
| 환경 | kind(노트북 사양·Docker 메모리) 또는 EKS(노드 타입·수) |
| overlay | dev / perf |
| 시나리오 | 01 방송 시작 폭주 / 02 쿠폰 드롭 / 03 Redis 장애 / 04 파티션 튜닝 |
| 부하 조건 | USERS=, RAMP=, HOLD=, SSE 연결 수(sse-holder --count) |
| k6 testid | `run.sh` 가 출력한 값. Grafana "06 · 부하 테스트"의 testid 변수와 같다 |
| 바꾼 설정 | 직전 측정 대비 바꾼 것 하나 (파티션 수, maxReplicaCount, lagThreshold, requests …) |

## 결과

절차는 **기준선 → 깨지는 지점 찾기 → 설정 하나 바꾸기 → 재측정** 이다. 한 행이 한 번의 실행이다.

| 실행 | USERS | 바꾼 설정 | notification 랙 해소 시간 | live 파드 수 (최대) | SSE 연결 수 (최대) | p99 지연 (heartbeat / claim) | 실패율 | 503 지속 시간 (시나리오 3) | 중복 발급 (시나리오 2) |
|---|---|---|---|---|---|---|---|---|---|
| 기준선 | | 없음 | | | | | | | |
| 깨지는 지점 | | 없음 | | | | | | | |
| 변경 1 | | | | | | | | | |
| 변경 2 | | | | | | | | | |

읽는 법
- **랙 해소 시간**: Grafana 랙 패널에서 방송 시작(k6 로그의 `started at`) 뒤 `notification-service` 랙이 처음 0 으로 돌아오기까지.
- **p99**: k6 요약의 `http_req_duration{name:heartbeat}` 또는 `{name:claim}` p(99). 서버 쪽 p99(`http_server_requests`)와 차이가 크면 Gateway 나 노트북 네트워크가 끼어든 것이다.
- **503 지속 시간**: k6 요약의 `viewer_count_outage_seconds` max. 파드 삭제 시각은 함께 적는다.
- **중복 발급**: `coupon_issued` 가 쿠폰 한도를 넘으면 중복이다. 같은 사용자의 두 번째 클릭은 200 이어야 한다.

## 판단

- 이 측정으로 정한 값: (예: `lagThreshold: 100` 유지 / live `연결 500 / 파드` 로 확정)
- 다음에 바꿔 볼 것 하나:
- 캡처: Grafana 06 대시보드 (testid 필터) 스크린샷을 `docs/assets/performance/` 에 넣고 링크
