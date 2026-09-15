# k8s

Kubernetes 매니페스트. kustomize base + overlay 구조.

```
k8s/
├── base/
│   ├── {member,shopping,commerce,live,notification}-service/
│   │   └── {deployment.yaml,service.yaml,kustomization.yaml}
│   ├── ingress.yaml          # 5개 서비스의 단일 진입점 (path 라우팅)
│   └── kustomization.yaml
└── overlays/{dev,perf,demo}/kustomization.yaml
```

## 진입점

별도 API 게이트웨이 서비스를 두지 않는다. `base/ingress.yaml` 이 경로로 서비스를 가른다.

| 경로 | 서비스 |
|---|---|
| `/api/member/**` | `member-service:8080` |
| `/api/shopping/**` | `shopping-service:8080` |
| `/api/commerce/**` | `commerce-service:8080` |
| `/api/live/**` | `live-service:8080` |
| `/api/notification/**` | `notification-service:8080` |

Frontend 는 이 Ingress 엔드포인트 하나만 호출한다.
경로 prefix 는 백엔드로 넘길 때 제거된다 — `/api/member/v1/users/1` → member-service 는 `/v1/users/1` 로 받는다.

**전제: 클러스터에 ingress-nginx 컨트롤러가 있어야 한다.** `rewrite-target` 과 정규식 캡처 그룹은 ingress-nginx 전용 문법이다.

## 포트

컨테이너 포트는 5개 서비스 모두 **8080** 으로 통일한다.
서비스별 포트(member 8081 … notification 8085)는 **로컬에서 5개를 한 호스트에 동시에 띄울 때만** 쓴다.

## 환경별 차이

`base` 는 환경 공통이고, 차이는 overlay 의 patch 로만 표현한다. 현재는 replica 수, 리소스 값, `SPRING_PROFILES_ACTIVE` 세 가지뿐이다.

| overlay | namespace | prefix | replicas | 성격 |
|---|---|---|---|---|
| `dev` | `shoppinglive-dev` | `dev-` | 1 | 기능 확인용 최소 구성 |
| `perf` | `shoppinglive-perf` | `perf-` | 2 | 부하 테스트, 추후 HPA 부착 |
| `demo` | `shoppinglive-demo` | `demo-` | 2 | 시연용 고정 |

overlay 의 patch 는 JSON 6902 로 `containers/0` 을 지정한다.
컨테이너 이름이 서비스마다 달라 strategic merge 로는 한 번에 못 고치기 때문이다.
모든 Deployment 가 컨테이너 1개짜리 같은 모양이라는 전제가 깨지면 patch 를 서비스별로 나눠야 한다.

## 확인

```sh
kubectl kustomize k8s/base
kubectl kustomize k8s/overlays/dev
```

`.github/workflows/k8s-validate.yml` 이 PR 마다 세 overlay 를 전부 렌더링해 본다.

## 이미지 태그

지금은 `ghcr.io/2026-2-rising-sun/<service>:latest` placeholder다.
Backend CI 가 이미지를 푸시하기 시작하면 커밋 SHA 기반 고정 태그로 바꾼다 (`argocd/README.md` 참고).
