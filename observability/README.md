# observability

**상태: 골격만.** 실제 설정은 배포 대상 클러스터가 생긴 뒤 채운다.

```
observability/
├── prometheus/   # 스크레이프 설정, 알림 규칙
└── grafana/      # 대시보드 정의, 데이터소스
```

## 향후 계획

- Backend 5개 서비스는 Spring Boot Actuator 를 포함하므로 `/actuator/prometheus` 노출 → Prometheus 스크레이프가 첫 단계다.
- 설치 방식(kube-prometheus-stack Helm 차트 vs 직접 매니페스트)은 아직 안 정했다.
- 대시보드는 최소한 서비스별 요청량/에러율/p99 지연, JVM 힙, Kafka consumer lag 을 다뤄야 한다.

## 분산 트레이싱

트레이싱 백엔드(Jaeger/Tempo/OTel Collector) 도입은 향후 과제다.
그 전까지는 Backend `libs/common-web` 의 correlation-id(`X-Request-Id`) 전파 필터로 로그를 이어 붙여 추적한다.
