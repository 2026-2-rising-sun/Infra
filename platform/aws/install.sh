#!/usr/bin/env bash
# EKS 클러스터 안에 플랫폼 부품을 설치한다. terraform apply 뒤, 앱 배포 전에 한 번 돌린다. 다시 돌려도 안전하다.
#
#   1. kubeconfig 갱신
#   2. AWS Load Balancer Controller (Service → NLB)
#   3. Karpenter + NodePool/EC2NodeClass
#   4. ArgoCD
#   5. ArgoCD AppProject + 루트 Application (App of Apps) → Envoy Gateway, Strimzi, KEDA 를 ArgoCD 가 설치
#   6. 플랫폼 CRD 가 생길 때까지 대기
#   7. GatewayClass + NLB 용 EnvoyProxy
#   8. RDS 에 서비스별 DB 생성
#
# 전제: aws CLI 로그인, helm, kubectl, terraform. Terraform output 은 terraform/envs/dev 에서 읽는다.
set -euo pipefail

source "$(dirname "$0")/common.sh"
LB_CONTROLLER_CHART_VERSION=3.6.1   # https://github.com/aws/eks-charts stable/aws-load-balancer-controller
KARPENTER_VERSION=1.15.0            # https://github.com/aws/karpenter-provider-aws
ARGOCD_CHART_VERSION=10.10.5        # https://github.com/argoproj/argo-helm charts/argo-cd


# __KEY__ 자리를 Terraform output 으로 바꿔 stdout 으로 낸다. envsubst 는 macOS 기본에 없어서 sed 를 쓴다.
render() {
  sed \
    -e "s|__CLUSTER_NAME__|$CLUSTER_NAME|g" \
    -e "s|__AWS_REGION__|$AWS_REGION|g" \
    -e "s|__VPC_ID__|$VPC_ID|g" \
    -e "s|__NODE_ROLE__|$NODE_ROLE|g" \
    -e "s|__INTERRUPTION_QUEUE__|$INTERRUPTION_QUEUE|g" \
    -e "s|__NLB_SECURITY_GROUP__|$NLB_SECURITY_GROUP|g" \
    -e "s|__ORIGIN_CERTIFICATE_ARN__|$ORIGIN_CERTIFICATE_ARN|g" \
    -e "s|__APP_NAMESPACE__|$APP_NAMESPACE|g" \
    "$1"
}

step() { printf '\n==> %s\n' "$*"; }

aws_context
NODE_ROLE=$(tf_out karpenter_node_role_name)
INTERRUPTION_QUEUE=$(tf_out karpenter_interruption_queue)
NLB_SECURITY_GROUP=$(tf_out nlb_security_group_id)
ORIGIN_CERTIFICATE_ARN=$(tf_out origin_certificate_arn)
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query cluster.resourcesVpcConfig.vpcId --output text)

step "1/8 kubeconfig: $CLUSTER_NAME ($AWS_REGION)"
kubectl config current-context

step "2/8 AWS Load Balancer Controller $LB_CONTROLLER_CHART_VERSION"
helm repo add eks https://aws.github.io/eks-charts >/dev/null
helm repo update eks >/dev/null
render "$ROOT/platform/aws/values/aws-load-balancer-controller.yaml" | helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system --version "$LB_CONTROLLER_CHART_VERSION" --values - --wait

step "3/8 Karpenter $KARPENTER_VERSION"
kubectl create namespace karpenter --dry-run=client -o yaml | kubectl apply -f -
render "$ROOT/platform/aws/values/karpenter.yaml" | helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter --version "$KARPENTER_VERSION" --values - --wait
for f in ec2nodeclass nodepool-app nodepool-kafka; do
  render "$ROOT/platform/aws/karpenter/$f.yaml" | kubectl apply -f -
done

step "4/8 ArgoCD chart $ARGOCD_CHART_VERSION"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update argo >/dev/null
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install argocd argo/argo-cd --namespace argocd --version "$ARGOCD_CHART_VERSION" \
  --values "$ROOT/platform/aws/values/argocd.yaml" --wait

step "5/8 ArgoCD AppProject + 루트 Application (Envoy Gateway·Strimzi·KEDA 는 ArgoCD 가 설치한다)"
# kind 에서는 platform/kind/components/*.sh 가 helm 으로 직접 깔지만, AWS 에서는 같은 차트·같은 버전을 ArgoCD 가 관리한다.
# 둘 다 쓰면 helm 릴리스와 ArgoCD 가 같은 리소스를 두고 싸운다. 버전은 argocd/applications/platform/*.yaml 과 components 스크립트에서 같게 맞춘다.
kubectl apply -f "$ROOT/argocd/projects/"
kubectl apply -f "$ROOT/argocd/bootstrap/root-app.yaml"

step "6/8 플랫폼 CRD 대기"
for crd in gatewayclasses.gateway.networking.k8s.io envoyproxies.gateway.envoyproxy.io kafkas.kafka.strimzi.io scaledobjects.keda.sh securitypolicies.gateway.envoyproxy.io; do
  printf '  %s ' "$crd"
  for _ in $(seq 1 60); do kubectl get crd "$crd" >/dev/null 2>&1 && break; sleep 5; done
  kubectl get crd "$crd" >/dev/null || { echo "CRD 대기 실패: $crd" >&2; exit 1; }
  echo ok
done

step "7/8 GatewayClass + Envoy Gateway → NLB"
kubectl create namespace "$APP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$ROOT/platform/aws/envoy-gateway/gatewayclass.yaml"
render "$ROOT/platform/aws/envoy-gateway/envoyproxy-nlb.yaml" | kubectl apply -f -
# 비밀값은 argv/로그에 넣지 않는다. 정책 생성 실패 시 Gateway를 공개하지 않는다.
terraform -chdir="$TF_DIR" output -json | python3 "$ROOT/platform/aws/envoy-gateway/origin-policy.py" "$APP_NAMESPACE" | kubectl apply --server-side -f -
render "$ROOT/platform/aws/envoy-gateway/gateway.yaml" | kubectl apply -f -

step "8/8 RDS 서비스별 DB"
"$ROOT/platform/aws/rds-init.sh"

cat <<EOF

설치 끝. 다음 확인:
  kubectl get nodes                                   # 시스템 노드 2대
  kubectl -n karpenter get pods                       # Karpenter Running
  kubectl -n argocd get applications                  # 루트 앱 Synced
  kubectl -n $APP_NAMESPACE get svc                   # Envoy Service 의 EXTERNAL-IP 에 NLB 주소가 생기면 make aws-up 이 CloudFront 에 연결한다
AWS 전용 앱 overlay·이미지·설정 배포와 실제 서비스 검증은 별도 단계다.
EOF
