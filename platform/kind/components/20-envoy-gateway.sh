# Envoy Gateway: Gateway API 리소스를 읽어 Envoy 프록시를 띄우는 컨트롤러.
# 차트는 Docker Hub OCI 에서 받는다. 네임스페이스 envoy-gateway-system.
ENVOY_GATEWAY_VERSION=v1.9.2

helm_install eg oci://docker.io/envoyproxy/gateway-helm envoy-gateway-system "$ENVOY_GATEWAY_VERSION"
wait_deploy envoy-gateway-system envoy-gateway
# GatewayClass(envoy-gateway)와 kind 용 EnvoyProxy(NodePort 30080). k8s/base/gateway 의 Gateway 가 이 클래스를 쓴다.
k apply -f "$here/envoy-gateway/gatewayclass.yaml"
k wait --for=condition=Accepted gatewayclass/envoy-gateway --timeout=60s
