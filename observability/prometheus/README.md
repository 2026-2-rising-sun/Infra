# observability/prometheus

**상태: 골격만.** Prometheus 스크레이프 설정과 알림 규칙이 들어갈 자리다.

설치 방식(kube-prometheus-stack Helm 차트 vs 직접 매니페스트)을 먼저 정해야 한다.
첫 스크레이프 대상은 각 서비스의 `/actuator/prometheus` 다.
