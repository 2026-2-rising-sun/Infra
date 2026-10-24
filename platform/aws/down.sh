#!/usr/bin/env bash
# 개발 환경 삭제. bootstrap 상태 버킷만 남고 RDS·ECR 이미지·프런트 파일은 삭제된다.
set -euo pipefail
source "$(dirname "$0")/common.sh"
terraform -chdir="$TF_DIR" init -backend-config=backend.hcl -input=false >/dev/null
aws_context
printf '삭제 대상: %s (%s)\nRDS 데이터·ECR 이미지·프런트 파일도 삭제됩니다.\n' "$CLUSTER_NAME" "$AWS_REGION"
read -r -p "계속하려면 클러스터 이름을 입력하세요: " confirmation
[ "$confirmation" = "$CLUSTER_NAME" ] || { echo '취소했습니다.' >&2; exit 1; }
# 조회 실패나 회수 시간 초과를 성공으로 바꾸지 않는다. 이 단계가 성공해야 destroy로 넘어간다.
python3 "$ROOT/platform/aws/cleanup.py" "$APP_NAMESPACE" "$AWS_REGION" "$CLUSTER_NAME"
terraform -chdir="$TF_DIR" destroy
rm -f "$TF_DIR/aws-runtime.auto.tfvars.json"
echo 'Terraform 환경 삭제 완료. 별도 bootstrap 상태 버킷은 남습니다. 잔여 자원은 별도 확인하세요.'
