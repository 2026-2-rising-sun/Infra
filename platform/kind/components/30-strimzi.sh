# Strimzi: Kafka CR(Kafka, KafkaNodePool, KafkaTopic)을 읽어 브로커와 토픽을 만드는 오퍼레이터.
# 차트는 GitHub 릴리스 자산(.tgz)을 바로 설치한다 (strimzi.io 차트 저장소와 내용이 같다).
# 앱 네임스페이스마다 Kafka CR 을 두므로 전체 네임스페이스를 감시한다.
STRIMZI_VERSION=1.3.0

helm_install strimzi \
  "https://github.com/strimzi/strimzi-kafka-operator/releases/download/${STRIMZI_VERSION}/strimzi-kafka-operator-helm-3-chart-${STRIMZI_VERSION}.tgz" \
  strimzi-system "$STRIMZI_VERSION" --set watchAnyNamespace=true
wait_deploy strimzi-system strimzi-cluster-operator
