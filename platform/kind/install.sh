#!/usr/bin/env bash
# 로컬 kind 클러스터에 플랫폼 구성 요소를 순서대로 설치한다.
#   ./platform/kind/install.sh            # components/*.sh 를 파일명 순서로 전부 실행
#   ./platform/kind/install.sh 30         # 번호가 30 으로 시작하는 것만
# 각 component 는 멱등이라 다시 실행해도 안전하다. 앱(k8s/overlays)은 여기서 올리지 않는다.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"
require_tools

filter="${1:-}"
for component in "$here"/components/*.sh; do
  name=$(basename "$component")
  case "$name" in "$filter"*) ;; *) continue ;; esac
  echo "==> $name"
  # shellcheck disable=SC1090
  . "$component"
done
echo "플랫폼 설치 완료 (컨텍스트: $KUBE_CONTEXT)"
