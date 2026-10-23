#!/usr/bin/env bash
# make aws-up: AWS 환경을 처음부터 끝까지 올린다. 멱등이라 중간에 실패하면 다시 돌린다.
#
#   1. terraform apply (VPC·EKS·RDS·ECR·CloudFront·IAM)       약 20분
#   2. platform/aws/install.sh (컨트롤러·ArgoCD·플랫폼 부품)    약 10분
#   3. NLB 주소가 생기길 기다려 nlb_dns_name 으로 두 번째 apply   약 3분 (CloudFront → NLB 연결)
#
# 전제: terraform/bootstrap 을 한 번 apply 했고, envs/dev 에 backend.hcl 과 terraform.tfvars 가 있다.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TF_DIR="$ROOT/terraform/envs/dev"
APP_NAMESPACE=${APP_NAMESPACE:-shoppinglive-dev}

for f in backend.hcl terraform.tfvars; do
  [ -f "$TF_DIR/$f" ] || { echo "$TF_DIR/$f 가 없다. $f.example 을 복사해 채운다." >&2; exit 1; }
done

echo "==> terraform apply (1/3)"
terraform -chdir="$TF_DIR" init -backend-config=backend.hcl -input=false >/dev/null
terraform -chdir="$TF_DIR" apply -input=false

echo "==> platform install (2/3)"
"$ROOT/platform/aws/install.sh"

echo "==> NLB 주소 대기 (3/3)"
NLB=""
for _ in $(seq 1 60); do
  NLB=$(kubectl -n "$APP_NAMESPACE" get svc -l gateway.envoyproxy.io/owning-gateway-name -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$NLB" ] && break
  sleep 10
done
if [ -z "$NLB" ]; then
  echo "10분 안에 NLB 가 생기지 않았다. Envoy Gateway 와 로드밸런서 컨트롤러 상태를 확인한 뒤 다시 make aws-up." >&2
  exit 1
fi
echo "NLB: $NLB"
terraform -chdir="$TF_DIR" apply -input=false -var "nlb_dns_name=$NLB"

DOMAIN=$(grep -E '^domain_name' "$TF_DIR/terraform.tfvars" | sed 's/.*= *"\(.*\)"/\1/')
cat <<EOF

완료. 서비스 주소: https://$DOMAIN  (CloudFront 전파에 몇 분 걸린다)
비용이 시간당 약 \$0.7 씩 나간다. 작업이 끝나면 make aws-down.
EOF
