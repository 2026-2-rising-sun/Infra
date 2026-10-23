# platform/kind

로컬 kind 클러스터에 앱 매니페스트(`k8s/`)가 전제하는 플랫폼 구성 요소를 설치한다. 앱은 여기서 올리지 않는다.

| 순서 | 구성 요소 | 버전 | 네임스페이스 | 왜 |
|---|---|---|---|---|
| 10 | Gateway API CRD (experimental 채널) | v1.6.1 | - | `k8s/base/gateway/` 의 Gateway·HTTPRoute 타입 |
| 20 | Envoy Gateway + GatewayClass `envoy-gateway` | v1.9.2 | `envoy-gateway-system` | Gateway API 를 실제 Envoy 프록시로 구현. ingress-nginx(2026-03 은퇴) 대체 |
| 30 | Strimzi 오퍼레이터 | 1.3.0 | `strimzi-system` | `k8s/overlays/dev/datatier/kafka.yaml` 의 Kafka·KafkaTopic CR 처리 |

```sh
kind create cluster --name shoppinglive-dev --config platform/kind/kind-config.yaml
./platform/kind/install.sh          # 전부
./platform/kind/install.sh 30       # Strimzi 만
KUBE_CONTEXT=kind-other ./platform/kind/install.sh
```

- 각 component 는 `helm upgrade --install` 이라 다시 실행해도 같은 상태로 수렴한다. 버전은 각 스크립트 맨 위 변수에서 올린다.
- Gateway API CRD 버전은 Envoy Gateway 가 번들하는 것과 맞춘다. helm 은 CRD 를 업그레이드하지 않아서 10 번이 따로 적용한다.
- `envoy-gateway/gatewayclass.yaml` 은 kind 용 EnvoyProxy(NodePort 30080)를 GatewayClass 에 붙인다. `kind-config.yaml` 이 그 포트를 호스트 9080 에 연다.
  이 설정 없이 만든 클러스터는 `k8s/local/port-forward-dev.sh` 가 같은 포트로 port-forward 한다.
- AWS 에서는 같은 차트를 쓰되 EnvoyProxy 를 NLB 용으로 바꾸고 ArgoCD 가 설치한다(terraform/argocd 단계).
- 팀 체험 환경(`make setup`, 클러스터 `shoppinglive-team`)은 아직 Frontend 의 스크립트가 Kafka 를 직접 띄운다. 그쪽 전환은 별도 작업이다.

관측 설정 생성 시 `python3 observability/local/deploy.py --app-namespace shoppinglive-dev`를 사용한다. dev의 Kafka exporter는 Strimzi의 `kafka-kafka-bootstrap`에 연결한다. 기존 팀 환경은 `kafka`를 유지하며 `--kafka-service`로 변경할 수 있다.
