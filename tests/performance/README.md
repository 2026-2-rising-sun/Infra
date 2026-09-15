# tests/performance

**상태: 골격만. 사용 툴 미정.**

`k8s/overlays/perf` 환경을 대상으로 한 부하 테스트 시나리오가 들어갈 자리다.
결과는 `docs/performance/` 에 기록한다.

## 정해야 할 것

- 도구: k6 / Gatling / Locust
- 시나리오: 라이브 방송 중 동시 시청 + 구매 몰림(스파이크)이 이 서비스의 핵심 부하 형태다
- 목표치(SLO): p99 지연·에러율 기준을 정해야 HPA 설정과 리소스 값에 근거가 생긴다
