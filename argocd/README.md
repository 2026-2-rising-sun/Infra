# argocd

GitOps 배포 정의. **아직 어떤 클러스터에도 적용하지 않았다.**

초기에는 매니페스트가 자주 바뀌므로 CI 의 `kubectl apply` 로 배포하고, 구조가 안정된 뒤 ArgoCD 를 붙인다.
여기 있는 파일들은 그 시점에 바로 쓸 수 있도록 미리 잡아 둔 골격이다.

```
argocd/
├── projects/shoppinglive-project.yaml   # AppProject: 허용 레포/네임스페이스 경계
└── applications/{dev,perf,demo}/shoppinglive.yaml
                                         # 각 환경이 k8s/overlays/<env> 를 가리킨다
```

## 붙일 때 확인할 것

- `destination.server` 를 실제 클러스터 주소로 교체 (지금은 in-cluster 기본값)
- **이미지 태그 갱신 방식이 아직 미정이다.** 현재 `k8s/base/*/deployment.yaml` 은 `:latest` 를 쓰는데,
  GitOps 에서는 커밋 SHA 같은 고정 태그를 써야 무엇이 배포됐는지 추적된다.
  Argo CD Image Updater / CI 가 kustomize `images:` 를 커밋 / Kargo 중 하나를 골라야 한다.
- dev 만 자동 동기화이고 perf/demo 는 수동이다. 부하 테스트·시연 도중 재배포를 막기 위함.
