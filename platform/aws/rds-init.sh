#!/usr/bin/env bash
# RDS 에 서비스별 DB 5개를 만든다. RDS 는 프라이빗 서브넷에만 있어서 노트북에서 직접 접속할 수 없다.
# 그래서 클러스터 안에 일회성 파드를 띄워 psql 을 실행한다. 비밀번호는 Secrets Manager 에서 읽어 파드 env 로만 넘긴다.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TF_DIR="$ROOT/terraform/envs/dev"

RDS_ADDRESS=$(terraform -chdir="$TF_DIR" output -raw rds_address)
SECRET_ARN=$(terraform -chdir="$TF_DIR" output -raw rds_master_user_secret_arn)
AWS_REGION=$(terraform -chdir="$TF_DIR" output -raw aws_region)

SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$AWS_REGION" --query SecretString --output text)
PGUSER=$(printf '%s' "$SECRET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])')
PGPASSWORD=$(printf '%s' "$SECRET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')

# --rm 이라 파드가 끝나면 사라진다. --env 는 kubectl run 이 파드 spec 에 넣고 로그에는 남기지 않는다.
kubectl run rds-init --rm -i --restart=Never --image=postgres:17-alpine \
  --env="PGHOST=$RDS_ADDRESS" --env="PGUSER=$PGUSER" --env="PGPASSWORD=$PGPASSWORD" --env="PGDATABASE=postgres" \
  --command -- psql -v ON_ERROR_STOP=1 < "$ROOT/platform/aws/rds/init.sql"
