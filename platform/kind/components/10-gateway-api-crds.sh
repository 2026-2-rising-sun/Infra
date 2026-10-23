# Gateway API CRD (Gateway, HTTPRoute, GatewayClass ...).
# Envoy Gateway 차트도 첫 설치 때 같은 CRD 를 넣지만 helm 은 CRD 를 업그레이드하지 않는다.
# 버전을 여기서 명시적으로 관리하려고 따로 적용한다. 이미 있으면 server-side apply 가 갱신만 한다.
# 채널은 experimental: Envoy Gateway v1.9 가 번들하는 채널과 같다(standard 로 바꾸면 EG 기능 일부가 빠진다).
# 버전은 Envoy Gateway 가 번들하는 것과 같게 둔다 (20-envoy-gateway.sh 를 올릴 때 같이 확인).
GATEWAY_API_VERSION=v1.6.1

k apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
k wait --for=condition=Established crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io --timeout=60s
