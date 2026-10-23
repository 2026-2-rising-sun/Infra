#!/usr/bin/env bash
# k6 시나리오를 실행하고 결과를 로컬 Prometheus 로 보낸다. Grafana "06 · 부하 테스트" 대시보드에서
# 파드 수·컨슈머 랙과 같은 시간축에 놓고 본다.
#
#   ./tests/performance/k6/run.sh 01 -e USERS=200            # 시나리오 번호 + k6 인자
#   BASE_URL=http://localhost:9080 ./tests/performance/k6/run.sh 02
#
# 전제
#   - seed.mjs 를 먼저 실행해 .seed/seed.json 이 있어야 한다.
#   - Prometheus 가 remote write 를 받으려면 --web.enable-remote-write-receiver 로 떠 있어야 한다
#     (observability/local/deploy.py 가 켠다). 노트북에서는 아래 PROM_URL 로 port-forward 한다.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
scenario=${1:?usage: run.sh <01|02|03|04|script.js> [k6 args...]}
shift

case "$scenario" in
  01) script="$here/01-broadcast-start-surge.js" ;;
  02) script="$here/02-coupon-drop.js" ;;
  03) script="$here/03-redis-failure.js" ;;
  04) script="$here/04-partition-tuning.js" ;;
  *) script="$scenario" ;;
esac

PROM_URL=${PROM_URL:-http://localhost:9090/api/v1/write}
TESTID=${TESTID:-$(basename "$script" .js)-$(date +%Y%m%dT%H%M%S)}
mkdir -p "$here/.results"

# Prometheus 가 열려 있지 않으면 remote write 없이 돌린다. 측정은 되고 Grafana 연결만 빠진다.
out=()
if curl -fsS -o /dev/null -X POST "$PROM_URL" 2>/dev/null || curl -fsS -o /dev/null "${PROM_URL%/api/v1/write}/-/ready" 2>/dev/null; then
  out=(-o experimental-prometheus-rw)
  export K6_PROMETHEUS_RW_SERVER_URL="$PROM_URL"
  export K6_PROMETHEUS_RW_TREND_STATS="p(95),p(99),max"
  export K6_PROMETHEUS_RW_STALE_MARKERS=true
else
  echo "Prometheus($PROM_URL) 에 연결되지 않아 remote write 없이 실행한다." >&2
fi

echo "testid=$TESTID  BASE_URL=${BASE_URL:-http://localhost:9080}  script=$(basename "$script")"
exec k6 run "${out[@]}" \
  --tag "testid=$TESTID" \
  --summary-export "$here/.results/$TESTID.json" \
  -e "BASE_URL=${BASE_URL:-http://localhost:9080}" \
  "$@" "$script"
