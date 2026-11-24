#!/usr/bin/env bash
set -euo pipefail
bootstrap="${KAFKA_BOOTSTRAP_SERVERS:-kafka:9092}"
while read -r topic partitions replicas cleanup retention; do
  [[ -z "$topic" || "$topic" == \#* ]] && continue
  configs=(--config "cleanup.policy=$cleanup")
  [[ "$retention" != "-" ]] && configs+=(--config "retention.ms=$retention")
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server "$bootstrap" \
    --create --if-not-exists --topic "$topic" --partitions "$partitions" \
    --replication-factor "$replicas" "${configs[@]}"
  # --if-not-exists는 기존 토픽 설정을 바꾸지 않으므로 보관 기간만 따로 맞춘다. partition 수는 바꾸지 않는다.
  if [[ "$retention" != "-" ]]; then
    /opt/kafka/bin/kafka-configs.sh --bootstrap-server "$bootstrap" --alter \
      --entity-type topics --entity-name "$topic" --add-config "retention.ms=$retention"
  fi
done < /init/topics.tsv
/opt/kafka/bin/kafka-topics.sh --bootstrap-server "$bootstrap" --list
