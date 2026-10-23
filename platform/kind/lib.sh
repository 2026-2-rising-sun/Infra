#!/usr/bin/env bash
# components/*.sh 가 공통으로 쓰는 함수. install.sh 가 source 한다.
# 전제: kubectl, helm(3.8 이상, OCI 차트 지원)이 PATH 에 있고 KUBE_CONTEXT 가 kind 클러스터를 가리킨다.

KUBE_CONTEXT="${KUBE_CONTEXT:-kind-shoppinglive-dev}"

k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

require_tools() {
  local t
  for t in kubectl helm; do
    command -v "$t" >/dev/null 2>&1 || { echo "필요한 도구가 없다: $t (macOS: brew install $t)" >&2; exit 1; }
  done
  case "$KUBE_CONTEXT" in
    kind-*) ;;
    *) echo "로컬 kind 컨텍스트만 허용한다: $KUBE_CONTEXT" >&2; exit 1 ;;
  esac
}

# helm_install <release> <chart> <namespace> <version> [helm 추가 인자...]
# upgrade --install 이라 다시 실행해도 같은 상태로 수렴한다. 버전은 호출하는 component 가 고정한다.
helm_install() {
  local release=$1 chart=$2 namespace=$3 version=$4
  shift 4
  helm --kube-context "$KUBE_CONTEXT" upgrade --install "$release" "$chart" \
    --namespace "$namespace" --create-namespace --version "$version" --wait --timeout 10m "$@"
}

# wait_deploy <namespace> <deployment> : 롤아웃이 끝날 때까지 기다린다.
wait_deploy() {
  k -n "$1" rollout status "deployment/$2" --timeout=5m
}
