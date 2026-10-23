#!/usr/bin/env bash
# make aws-down: AWS 환경을 지운다. 상태 저장소(bootstrap)와 ECR 이미지는 남는다.
#
# 순서가 중요하다. terraform destroy 만 하면 두 가지가 남아 과금된다.
#   - 로드밸런서 컨트롤러가 만든 NLB: Terraform 이 모르는 자원이라 destroy 가 못 지운다. Service 를 먼저 지워야 컨트롤러가 회수한다.
#   - Karpenter 가 만든 EC2: 같은 이유. NodePool 을 지우면 Karpenter 가 노드를 정리한다.
# 그래서 쿠버네티스 쪽을 먼저 비우고, 비워진 걸 확인한 뒤 destroy 한다.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TF_DIR="$ROOT/terraform/envs/dev"

CLUSTER_NAME=$(terraform -chdir="$TF_DIR" output -raw cluster_name 2>/dev/null || true)
AWS_REGION=$(terraform -chdir="$TF_DIR" output -raw aws_region 2>/dev/null || echo ap-northeast-2)

if [ -n "$CLUSTER_NAME" ] && aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

  echo "==> ArgoCD 가 다시 만들지 못하게 루트 앱부터 지운다"
  kubectl -n argocd delete application --all --ignore-not-found --timeout=120s || true

  echo "==> LoadBalancer Service 삭제 (NLB 회수)"
  kubectl get svc -A -o json | python3 -c '
import json,sys,subprocess
for s in json.load(sys.stdin)["items"]:
    if s["spec"].get("type")=="LoadBalancer":
        subprocess.run(["kubectl","-n",s["metadata"]["namespace"],"delete","svc",s["metadata"]["name"],"--ignore-not-found","--timeout=120s"])
'
  echo "==> NLB 가 사라질 때까지 대기"
  for _ in $(seq 1 30); do
    n=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --query "length(LoadBalancers[?contains(LoadBalancerName, 'k8s-')])" --output text 2>/dev/null || echo 0)
    [ "$n" = "0" ] && break
    sleep 10
  done

  echo "==> Karpenter NodePool 삭제 (EC2 회수)"
  kubectl delete nodepool --all --ignore-not-found --timeout=300s || true
  for _ in $(seq 1 30); do
    n=$(kubectl get nodeclaims -o name 2>/dev/null | wc -l | tr -d ' ')
    [ "$n" = "0" ] && break
    sleep 10
  done
fi

echo "==> terraform destroy"
terraform -chdir="$TF_DIR" init -backend-config=backend.hcl -input=false >/dev/null
terraform -chdir="$TF_DIR" destroy -input=false -var "nlb_dns_name="

echo "완료. 남은 것: terraform/bootstrap(상태 저장소), ECR 이미지. 콘솔 EC2·NLB·EBS 화면에서 잔여 자원이 없는지 한 번 본다."
