#!/usr/bin/env bash
# Backend 서비스 이미지를 로컬에서 만들어 kind 에 넣는다.
#
#   ./platform/kind/build-images.sh                 # 5개 전부, Backend 는 ../Backend
#   BACKEND_DIR=~/src/Backend ./platform/kind/build-images.sh live notification
#
# 왜 필요한가: k8s/base 의 Deployment 는 ghcr.io/2026-2-rising-sun/<서비스>-service 이미지를 가리키는데
# CI 가 아직 이미지를 올리지 않는다. 로컬에서는 Backend 레포의 Dockerfile 로 직접 만들고
# `:local` 태그로 kind 에 적재한다. k8s/overlays/dev 가 그 태그를 쓴다(images:).
# imagePullPolicy 가 IfNotPresent 라 레지스트리에 없어도 적재된 이미지를 쓴다.
#
# OTel 에이전트: 관측 스택(observability/local)이 trace 를 받으려면 JVM 에 javaagent 가 있어야 한다.
# Backend Dockerfile 은 에이전트를 넣지 않으므로, 빌드한 이미지 위에 한 겹 더 얹어 /otel/agent.jar 를 둔다.
# 버전과 체크섬은 observability/local/instrument.py 와 같다(팀 체험 환경과 같은 에이전트).
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=lib.sh
. "$here/lib.sh"

BACKEND_DIR=${BACKEND_DIR:-"$here/../../../Backend"}
TAG=${TAG:-local}
AGENT_URL=https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.20.0/opentelemetry-javaagent.jar
AGENT_SHA256=191666bf4346ab0677f92304bb272cd85f5954f49c03bb9636134e59c9a3276d

services=("$@")
[ ${#services[@]} -gt 0 ] || services=(member shopping commerce live notification)
[ -f "$BACKEND_DIR/settings.gradle.kts" ] || { echo "Backend 레포가 아니다: $BACKEND_DIR (BACKEND_DIR 로 지정)" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker 가 필요하다" >&2; exit 1; }
command -v kind >/dev/null || { echo "kind 가 필요하다" >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
curl -sSL -o "$work/agent.jar" "$AGENT_URL"
echo "$AGENT_SHA256  $work/agent.jar" | sha256sum -c - >/dev/null || { echo "OTel 에이전트 체크섬 불일치" >&2; exit 1; }
printf 'ARG BASE\nFROM ${BASE}\nCOPY --chown=spring:spring agent.jar /otel/agent.jar\n' > "$work/Dockerfile"

for s in "${services[@]}"; do
  image="ghcr.io/2026-2-rising-sun/$s-service"
  echo "==> $s-service"
  # Backend Dockerfile 의 build context 는 레포 루트다 (Dockerfile 상단 주석).
  # 첫 빌드는 컨테이너 안에서 Gradle 이 의존성을 받아 서비스당 수 분 걸린다. 이후는 캐시(--mount=type=cache)로 빨라진다.
  docker build -f "$BACKEND_DIR/services/$s-service/Dockerfile" -t "$image:app" "$BACKEND_DIR"
  docker build -q --build-arg "BASE=$image:app" -t "$image:$TAG" "$work" >/dev/null
  kind load docker-image "$image:$TAG" --name "${KUBE_CONTEXT#kind-}"
done
echo "적재 완료: ${services[*]} (태그 $TAG, 클러스터 ${KUBE_CONTEXT#kind-})"
echo "이미 떠 있는 파드에 반영하려면: kubectl -n shoppinglive-dev rollout restart deploy -l app.kubernetes.io/part-of=shoppinglive"
