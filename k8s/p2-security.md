# P2 인증 환경 입력

이 문서는 Kubernetes 참조 설정이다. Secret 생성·클러스터 적용·외부 배포 검증은 수행하지 않았다.
Backend의 P2 인증 구현과 같은 버전으로 적용하며, 기존 이미지는 이 설정의 동작 근거가 아니다.
Gateway·Frontend·데이터 계층 구성 변경은 포함하지 않는다.

## 관리 포트

Member·Shopping·Commerce·Live의 API 포트는 8080, 관리 포트는 9090이다.
각 Deployment의 readiness/liveness probe만 `management` 포트를 사용한다.
기존 Service와 Ingress는 `http`(8080)만 연결하며 9090 Service·Ingress는 만들지 않는다.
probe에는 사용자 JWT나 서비스 토큰을 넣지 않는다.
허용 health 응답은 readiness/liveness의 최소 상태이며 상세·구성요소는 숨긴다.
다른 actuator 경로는 서비스의 SecurityFilterChain에서 거부한다.
Notification은 이번 인증 범위 밖이며 기존 8080 health probe를 유지한다.

이 설정은 외부 Service/Ingress 경로를 분리한다. Pod IP에 직접 접근하는 클러스터 내부 통신까지 차단하는 NetworkPolicy는 아니다.
실제 배포 전에 애플리케이션 8080의 health 미노출, 9090의 무인증 probe 성공, DB 장애 시 readiness 실패를 검증해야 한다.
기존 `k8s/local/port-forward-dev.sh`의 9081~9084는 API 포트이므로 health 점검 주소로 사용하지 않는다.
관리 확인이 필요한 운영자는 해당 Deployment의 9090에 별도 port-forward를 사용한다.

## 환경별 필수 리소스

아래 리소스는 대상 namespace에서 운영자가 별도로 공급한다. 저장소에는 실제 값이나 키를 넣지 않는다.
참조 대상이 Kustomize resources에 없으므로 이름에는 `dev-`, `demo-`, `perf-` 접두사가 붙지 않는다.
namespace마다 서로 다른 키와 토큰을 사용하고 로컬 테스트·Mock 키를 외부 dev 신뢰키로 재사용하지 않는다.

| 종류 / 이름 | 필수 key | 소비자 |
| --- | --- | --- |
| ConfigMap `member-jwt-public` | `member-public.jwks` | Member·Shopping·Commerce·Live |
| Secret `member-jwt-private` | `member-private.pem` | Member만 |
| ConfigMap `member-auth-policy` | `key-id`, `access-token-ttl`, `refresh-token-ttl` | Member만 |
| Secret `shopping-commerce-service-token` | `token` | Shopping 발신·Commerce 수신 |
| Secret `commerce-shopping-service-token` | `token` | Commerce 발신·Shopping 수신 |
| Secret `live-shopping-service-token` | `token` | Live 발신·Shopping 수신 |
| Secret `live-commerce-service-token` | `token` | Live 발신·Commerce 수신 |

공개 JWKS 파일은 `/run/shoppinglive/jwt/member-public.jwks`에 읽기 전용으로 마운트한다.
JWKS에는 RSA 공개키만 넣으며 issuer `shoppinglive-member`, audience `shoppinglive-api` 정책과 함께 사용한다.
Member 개인키는 PKCS#8 PEM, RSA 2048비트 이상이며 `/run/shoppinglive/member-private/member-private.pem`에만 마운트한다.
Member는 kid와 공개키의 RSA 파라미터가 개인키와 일치하는지 기동 시 검사한다.
Member Pod의 `fsGroup: 20001`은 비루트 프로세스에 Secret 파일의 그룹 읽기를 제공하고 파일 모드는 0440이다.
다른 서비스에는 개인키 Secret volume이나 발급 정책을 넣지 않는다.

TTL은 기본값 없이 필수 환경값으로 전달한다. 양수·초 단위로 표현 가능한 Java Duration을 사용한다.
테스트에서 사용한 TTL은 운영 정책 승인이 아니며 이 저장소는 TTL 값을 결정하지 않는다.
access/refresh 만료 정책과 철회·탈퇴 동작을 승인한 뒤 `member-auth-policy`를 공급해야 한다.
리소스나 필수 key가 누락되면 Pod가 준비되지 않으며 임의 테스트키·기본 TTL로 우회하지 않는다.

## 서비스 호출 자격증명

| 환경변수 | 발신 → 수신 |
| --- | --- |
| `SHOPPING_COMMERCE_SERVICE_TOKEN` | Shopping → Commerce |
| `COMMERCE_SHOPPING_SERVICE_TOKEN` | Commerce → Shopping |
| `LIVE_SHOPPING_SERVICE_TOKEN` | Live → Shopping |
| `LIVE_COMMERCE_SERVICE_TOKEN` | Live → Commerce |

방향마다 서로 다른 고엔트로피 32자 이상 opaque 토큰을 공급한다. 같은 방향의 발신자와 수신자만 값을 공유한다.
수신 서비스는 `X-Service-Token`을 서버 설정과 비교해 caller를 결정하며 사용자·ADMIN JWT로 대체하지 않는다.
Secret은 필요한 key만 `secretKeyRef`로 읽고 `envFrom`으로 전체 Secret을 공유하지 않는다.
Secret 접근 RBAC·저장 시 암호화·운영 키 생성은 클러스터 운영자가 별도로 설정한다.
환경변수와 JWT decoder는 기동 시 읽으므로 갱신 뒤에는 관련 서비스를 재기동하고 정상·거부 경로를 다시 검증한다.
키·토큰 원문을 명령 출력, 로그, PR 또는 검증 artifact에 기록하지 않는다.

## 적용 전 확인

1. Backend에서 검증한 동일 SHA 이미지와 최종 인증 계약을 확인한다. 현재 base의 `latest`는 배포 고정 근거가 아니다.
2. 각 namespace에 해당 환경의 공개키·개인키·정책·방향별 토큰을 공급한다.
3. `kubectl kustomize k8s/overlays/dev` 등으로 참조와 포트를 확인한다.
4. 별도 승인된 배포에서 Pod Ready/재시작/probe event, 실제 Member 발급 토큰, 서비스 호출을 확인한다.
5. 잘못된 caller·사용자 JWT만 있는 내부 호출·일반 회원 관리 요청이 거부되는지 확인한다.

정적 렌더링 통과는 키의 적합성, 실제 서비스 연동 또는 클러스터 probe 통과를 의미하지 않는다.
기존 ingress-nginx 라우팅과 내부 API의 외부 경로 정책은 이번 포트 변경만으로 교체되지 않는다.
외부 dev 공개 전에 지원되는 Ingress/TLS 구성과 내부 경로 비공개 정책을 별도로 완료해야 한다.

근거: [Spring Boot 관리 포트](https://docs.spring.io/spring-boot/3.5/reference/actuator/monitoring.html),
[Kubernetes Secret 파일·환경변수](https://kubernetes.io/docs/concepts/configuration/secret/),
[보안 컨텍스트와 fsGroup](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/).
