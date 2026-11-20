#!/usr/bin/env bash
set -euo pipefail
bootstrap="${KAFKA_BOOTSTRAP_SERVERS:-kafka:9092}"
while read -r topic partitions replicas cleanup; do
  [[ -z "$topic" || "$topic" == \#* ]] && continue
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server "$bootstrap" \
    --create --if-not-exists --topic "$topic" --partitions "$partitions" \
    --replication-factor "$replicas" --config "cleanup.policy=$cleanup"
done < /init/topics.tsv
/opt/kafka/bin/kafka-topics.sh --bootstrap-server "$bootstrap" --list
