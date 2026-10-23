# argocd

GitOps 배포 정의. App of Apps 구조로, 루트 Application 하나를 apply 하면 나머지는 ArgoCD 가 main 브랜치를 읽어 만든다.

```
argocd/
├── bootstrap/root-app.yaml              # 루트. platform/aws/install.sh 가 apply 한다
├── projects/
│   ├── shoppinglive-project.yaml        # 앱 경계: 이 레포, shoppinglive-* 네임스페이스, 클러스터 범위는 Namespace 만
│   └── platform-project.yaml            # 플랫폼 경계: 외부 Helm 저장소, CRD·ClusterRole 허용
└── applications/                        # 루트가 재귀로 읽는다
    ├── platform/{envoy-gateway,strimzi,keda}.yaml   # Helm 차트. 버전은 platform/kind/components 와 같다
    └── {dev,perf,demo}/shoppinglive.yaml            # k8s/overlays/<env> (kustomize)
```

ArgoCD 자체는 Helm 으로 설치한다(`platform/aws/install.sh`, values 는 `platform/aws/values/argocd.yaml`). 자기 자신을 GitOps 로 관리하는 구성은 하지 않는다. 설치 도구가 망가졌을 때 복구 경로가 하나 더 생길 뿐이다.

## 결정한 것

| 항목 | 결정 | 이유 |
|---|---|---|
| 이미지 태그 갱신 | **CI 가 kustomize `images:` 를 커밋** | Backend 워크플로가 ECR 에 `:<sha>` 를 올린 뒤 `k8s/overlays/<env>/kustomization.yaml` 의 `images` 를 바꾸는 PR 을 만든다. 무엇이 언제 배포됐는지 git log 에 남는다. Image Updater 는 클러스터가 레지스트리를 폴링해 git 밖에서 상태가 바뀌고, Kargo 는 이 규모엔 과하다 |
| 동기화 | dev 자동, perf·demo 수동 | 부하 테스트·시연 중 재배포를 막는다 (기존 결정 유지) |
| 플랫폼 순서 | sync-wave: envoy-gateway·strimzi(-2) → keda(-1) → 앱(0) | CRD 가 먼저 있어야 Gateway·Kafka·ScaledObject 가 받아들여진다 |
| 접근 | port-forward 만 | `make argocd-ui`. 외부 노출과 GitHub 로그인(dex)은 후속 |

## 붙일 때 확인할 것

- `destination.server` 는 ArgoCD 가 자기 클러스터에 배포하므로 in-cluster 기본값 그대로 둔다.
- `k8s/overlays/<env>` 의 `images` 가 ECR 주소를 가리켜야 한다(`terraform output ecr_repository_urls`).
- 앱 Secret(JWT 키, 서비스 토큰)은 git 에 없다. AWS 에서는 Secrets Manager → External Secrets 로 공급하는 것이 후속 과제이고, 그 전까지는 `k8s/local/auth-secrets.sh` 를 EKS 컨텍스트에서 한 번 돌린다.
