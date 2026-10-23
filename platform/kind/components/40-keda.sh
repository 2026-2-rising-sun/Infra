# KEDA: ScaledObject(k8s/overlays/dev/scaling/)가 참조하는 CRD 와 컨트롤러.
#
# 왜 KEDA 인가: HPA 혼자서는 CPU·메모리만 본다. 우리 스케일링 신호는 Kafka 컨슈머 랙과
# Prometheus 지표(SSE 연결 수, 곧 시작할 방송의 알림 신청자 수)라서 HPA 에 외부 지표를
# 공급해 줄 어댑터가 필요하고, KEDA 가 그 역할(HPA 생성 + 외부 지표 서버)을 한다.
#
# 차트는 KEDA 공식 저장소(kedacore.github.io/charts)에서 `--repo` 로 직접 받는다. `helm repo add` 없이도 되어 상태가 남지 않는다.
# 처음에는 OCI(ghcr.io) 로 했는데, Docker Desktop 에 만료된 GitHub 로그인이 남아 있으면 helm 이 그 자격 증명을 보내
# 공개 차트인데도 403 이 난다(실제로 겪음). GitHub 릴리스에는 차트 .tgz 가 없어서(소스 zip 만) Strimzi 방식도 못 쓴다.
# install.sh 가 lib.sh 를 읽은 뒤 이 파일을 source 한다 (다른 component 와 같은 방식).
KEDA_VERSION=2.21.0   # 차트와 앱 버전이 같다 (2026-10 기준 최신 안정)
KEDA_REPO=https://kedacore.github.io/charts

# kind 단일 노드 기준의 작은 요청값. 운영(EKS)에서는 값을 올린다.
# metricServer 는 HPA 가 외부 지표를 물어보는 창구라 죽으면 스케일링이 멈춘다. 그래도 replica 1 로 둔다
# (kind 는 노드 1개, HA 는 EKS 단계에서 결정).
helm_install keda keda keda "$KEDA_VERSION" --repo "$KEDA_REPO" \
  --set resources.operator.requests.cpu=50m \
  --set resources.operator.requests.memory=128Mi \
  --set resources.metricServer.requests.cpu=50m \
  --set resources.metricServer.requests.memory=128Mi \
  --set resources.webhooks.requests.cpu=20m \
  --set resources.webhooks.requests.memory=64Mi
wait_deploy keda keda-operator
wait_deploy keda keda-operator-metrics-apiserver
