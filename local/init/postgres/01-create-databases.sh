#!/bin/bash
# postgres 컨테이너 최초 기동 시(볼륨이 비어 있을 때)에만 실행된다.
# POSTGRES_MULTIPLE_DATABASES 에 콤마로 나열된 서비스별 DB 를 하나씩 만든다.
# 이미 데이터 볼륨이 있으면 실행되지 않으므로, DB 목록을 바꿨다면
#   docker compose -f local/docker-compose.yml down -v
# 로 볼륨을 지우고 다시 올려야 한다.
set -euo pipefail

if [ -z "${POSTGRES_MULTIPLE_DATABASES:-}" ]; then
  echo "POSTGRES_MULTIPLE_DATABASES is not set, skipping per-service database creation"
  exit 0
fi

create_database() {
  local database="$1"
  echo "Creating database '${database}' owned by '${POSTGRES_USER}'"
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<-EOSQL
    CREATE DATABASE "${database}" OWNER "${POSTGRES_USER}";
EOSQL
}

echo "Multiple database creation requested: ${POSTGRES_MULTIPLE_DATABASES}"
IFS=',' read -ra databases <<< "${POSTGRES_MULTIPLE_DATABASES}"
for database in "${databases[@]}"; do
  create_database "$(echo "${database}" | tr -d '[:space:]')"
done
echo "Per-service databases created"
