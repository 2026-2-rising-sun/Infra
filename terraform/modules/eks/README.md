# terraform/modules/eks

EKS 클러스터와 노드그룹을 정의할 모듈. `k8s/overlays/{dev,perf,demo}` 매니페스트가 배포될 대상 클러스터다.

**상태: 향후 정의.** 팀이 AWS 사용 범위를 합의한 뒤 채운다.

채울 때 최소한 다음을 결정해야 한다.

- 쿠버네티스 버전과 노드그룹 인스턴스 타입/스케일 범위
- ingress-nginx 컨트롤러 설치 방식 (`k8s/base/ingress.yaml` 이 nginx 전제로 작성돼 있음)
- IRSA(서비스 어카운트 IAM 역할) 필요 범위 — RDS/IVS/S3 접근 경로
