#!/usr/bin/env bash
# 로컬 클러스터의 dev 리소스를 호스트 포트로 한 번에 연결한다. Ctrl+C 로 전부 끊는다.
#
#   ./k8s/local/port-forward-dev.sh
#
# 호스트 포트를 고른 기준:
#   - 서비스 908x: IntelliJ 로컬 실행 포트(808x)와 겹치지 않게 끝자리만 맞췄다.
#   - postgres/redis 25432/26379: local/docker-compose.yml 이 5432/6379 를 쓰고 있어도 같이 띄울 수 있게 했다.
#   - Kafka 브로커는 연결하지 않는다. 브로커가 자기 주소를 클러스터 내부 주소로 광고해서
#     호스트 클라이언트는 부트스트랩 이후 접속하지 못한다. 대신 Kafka UI 를 쓴다.
#   - Gateway(API 진입점) 9080: Envoy Service 는 envoy-gateway-system 에 생기고 이름 끝에 해시가 붙어 라벨로 찾는다.
#     platform/kind/kind-config.yaml 로 만든 클러스터는 NodePort 가 이미 호스트 9080 에 열려 있어 건너뛴다.
set -euo pipefail

NS="${NS:-shoppinglive-dev}"

# 호스트포트:Service:Service포트
FORWARDS=(
  "9081:dev-member-service:8080"
  "9082:dev-shopping-service:8080"
  "9083:dev-commerce-service:8080"
  "9084:dev-live-service:8080"
  "9085:dev-notification-service:8080"
  "25432:postgres:5432"
  "26379:redis:6379"
  "28080:kafka-ui:8080"
  "25540:redisinsight:5540"
)

pids=()
cleanup() {
  # macOS 기본 bash 3.2 에서 빈 배열을 set -u 로 펼치면 오류가 나서 이렇게 쓴다.
  kill ${pids[@]+"${pids[@]}"} 2>/dev/null || true
}
trap cleanup EXIT INT TERM

GATEWAY_NAME="${GATEWAY_NAME:-dev-shoppinglive}"
gw_svc=$(kubectl get svc -n envoy-gateway-system \
  -l "gateway.envoyproxy.io/owning-gateway-namespace=$NS,gateway.envoyproxy.io/owning-gateway-name=$GATEWAY_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$gw_svc" ]; then
  echo "skip  gateway (Envoy Service 없음 — platform/kind/install.sh 와 Gateway 적용 여부 확인)"
elif (exec 3<>/dev/tcp/127.0.0.1/9080) 2>/dev/null; then
  echo "skip  gateway (localhost:9080 이미 열림 — kind extraPortMappings)"
else
  kubectl port-forward -n envoy-gateway-system "svc/$gw_svc" 9080:80 >/dev/null &
  pids+=("$!")
  echo "open  localhost:9080 -> $gw_svc:80 (API 진입점)"
fi

for entry in "${FORWARDS[@]}"; do
  IFS=: read -r host_port svc svc_port <<< "$entry"
  if ! kubectl get svc "$svc" -n "$NS" >/dev/null 2>&1; then
    echo "skip  $svc (Service 없음)"
    continue
  fi
  kubectl port-forward -n "$NS" "svc/$svc" "$host_port:$svc_port" >/dev/null &
  pids+=("$!")
  echo "open  localhost:$host_port -> $svc:$svc_port"
done

echo
echo "연결 유지 중. Ctrl+C 로 종료."
echo "파드가 재시작되면 해당 연결이 끊기므로 스크립트를 다시 실행한다."
wait
