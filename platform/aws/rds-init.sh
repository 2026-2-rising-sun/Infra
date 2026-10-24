#!/usr/bin/env bash
# 비밀번호를 argv에 넣지 않고 단기 Secret을 참조하는 파드에서 DB를 초기화한다.
set -euo pipefail
source "$(dirname "$0")/common.sh"
aws_context
python3 "$ROOT/platform/aws/rds_init.py" "$TF_DIR" "$AWS_REGION" "$APP_NAMESPACE"
