#!/bin/sh
# KEDA 설치. ScaledObject(k8s/overlays/dev/scaling/)가 참조하는 CRD 와 컨트롤러를 넣는다.
#
# 왜 KEDA 인가: HPA 혼자서는 CPU·메모리만 본다. 우리 스케일링 신호는 Kafka 컨슈머 랙,
# Prometheus 지표(SSE 연결 수, 곧 시작할 방송의 알림 신청자 수)라서 HPA 에 외부 지표를
# 공급해 줄 어댑터가 필요하고, KEDA 가 그 역할(HPA 생성 + 외부 지표 서버)을 한다.
#
# 멱등: helm upgrade --install 이라 두 번 실행해도 같은 상태가 된다.
# 차트는 OCI 레지스트리(ghcr.io)에서 받는다. `helm repo add` 가 필요 없어서 상태가 남지 않는다.
#
# 사용: platform/kind/install.sh 가 파일명 순서로 호출한다. 단독 실행도 된다.
#   sh platform/kind/components/40-keda.sh
set -eu

KEDA_VERSION="${KEDA_VERSION:-2.21.0}"     # 차트와 앱 버전이 같다 (2026-10 기준 최신 안정)
KEDA_NAMESPACE="${KEDA_NAMESPACE:-keda}"
HELM="${HELM:-helm}"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# 1단계가 두는 공통 helm 래퍼가 있으면 그것을 쓴다. 없으면 아래 helm 직접 호출로 동작한다.
if [ -f "$script_dir/../lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$script_dir/../lib.sh"
fi

# kind 단일 노드 기준의 작은 요청값. 운영(EKS)에서는 overlay 값으로 올린다.
# metricServer 는 HPA 가 외부 지표를 물어보는 창구라 죽으면 스케일링이 멈춘다. 그래도 replica 1 로 둔다
# (kind 는 노드 1개, HA 는 EKS 단계에서 결정).
"$HELM" upgrade --install keda oci://ghcr.io/kedacore/charts/keda \
  --version "$KEDA_VERSION" \
  --namespace "$KEDA_NAMESPACE" --create-namespace \
  --set resources.operator.requests.cpu=50m \
  --set resources.operator.requests.memory=128Mi \
  --set resources.metricServer.requests.cpu=50m \
  --set resources.metricServer.requests.memory=128Mi \
  --set resources.webhooks.requests.cpu=20m \
  --set resources.webhooks.requests.memory=64Mi \
  --wait --timeout 5m

echo "keda $KEDA_VERSION ready in namespace $KEDA_NAMESPACE"
