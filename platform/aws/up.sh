#!/usr/bin/env bash
# make aws-up: AWS 플랫폼을 올린다. 앱 배포는 별도이며 apply마다 변경 계획을 확인한다.
#
#   1. terraform apply (VPC·EKS·RDS·ECR·CloudFront·IAM)       약 20분
#   2. platform/aws/install.sh (컨트롤러·ArgoCD·플랫폼 부품)    약 10분
#   3. NLB 주소가 생기길 기다려 nlb_dns_name 으로 두 번째 apply   약 3분 (CloudFront → NLB 연결)
#
# 전제: terraform/bootstrap 을 한 번 apply 했고, envs/dev 에 backend.hcl 과 terraform.tfvars 가 있다.
set -euo pipefail

source "$(dirname "$0")/common.sh"

for f in backend.hcl terraform.tfvars; do
  [ -f "$TF_DIR/$f" ] || { echo "$TF_DIR/$f 가 없다. $f.example 을 복사해 채운다." >&2; exit 1; }
done

echo "==> terraform apply (1/3)"
terraform -chdir="$TF_DIR" init -backend-config=backend.hcl -input=false >/dev/null
terraform -chdir="$TF_DIR" apply

aws_context

echo "==> platform install (2/3)"
"$ROOT/platform/aws/install.sh"

echo "==> NLB 주소 대기 (3/3)"
NLB=""
for _ in $(seq 1 60); do
  NLB=$(kubectl -n "$APP_NAMESPACE" get svc -l gateway.envoyproxy.io/owning-gateway-name=shoppinglive -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}')
  [ -n "$NLB" ] && break
  sleep 10
done
if [ -z "$NLB" ]; then
  echo "10분 안에 NLB 가 생기지 않았다. Envoy Gateway 와 로드밸런서 컨트롤러 상태를 확인한 뒤 다시 make aws-up." >&2
  exit 1
fi
[[ "$NLB" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo 'NLB 주소가 여러 개이거나 형식이 잘못되었습니다.' >&2; exit 1; }
echo "NLB: $NLB"
# 다음 실행의 첫 apply도 기존 NLB CNAME을 유지한다. 파일은 커밋하지 않는다.
python3 - "$TF_DIR/aws-runtime.auto.tfvars.json" "$NLB" <<'PYCONFIG'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({"nlb_dns_name": sys.argv[2]}))
PYCONFIG
terraform -chdir="$TF_DIR" apply

echo "AWS 플랫폼 준비 완료. AWS 전용 앱 overlay·이미지·설정 배포와 서비스 검증은 별도입니다."
echo "작업이 끝나면 make aws-down. RDS 데이터·ECR 이미지·프런트 파일도 삭제되는 개발 환경입니다."
