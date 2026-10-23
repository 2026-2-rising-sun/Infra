# kind의 자체 서명 kubelet 인증서 때문에 이 로컬 전용 overlay만 TLS 검증을 생략한다.
# KEDA의 CPU 트리거는 별도 metrics.k8s.io 서버가 필요하다. Kubernetes 1.31 이상 대상.
k apply -k "$here/metrics-server"
wait_deploy kube-system metrics-server
k wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=120s
