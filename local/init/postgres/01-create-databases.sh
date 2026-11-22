#!/bin/bash
# 최초 기동과 기존 볼륨의 수동 재실행에 같은 목록을 사용한다.
# 이미 있는 DB와 소유자는 보존하고 빠진 DB만 만든다 (local/README.md).
set -euo pipefail

if [ -z "${POSTGRES_MULTIPLE_DATABASES:-}" ]; then
  echo "POSTGRES_MULTIPLE_DATABASES가 설정되지 않아 서비스별 DB 생성을 건너뜁니다"
  exit 0
fi

create_database() {
  local database="$1"
  if [[ ! "$database" =~ ^[a-z_][a-z0-9_]*$ ]] || (( ${#database} > 63 )); then
    echo "잘못된 DB 이름: ${database}" >&2
    return 1
  fi
  echo "DB 확인·추가: 이름='${database}' 소유자='${POSTGRES_USER}'"
  psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
    --set=database="$database" --set=owner="$POSTGRES_USER" <<'SQL'
SELECT format('CREATE DATABASE %I OWNER %I', :'database', :'owner')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'database')
\gexec
SQL
}

echo "서비스별 DB 생성 요청: ${POSTGRES_MULTIPLE_DATABASES}"
IFS=',' read -ra databases <<< "${POSTGRES_MULTIPLE_DATABASES}"
for database in "${databases[@]}"; do
  create_database "$(echo "${database}" | tr -d '[:space:]')"
done
echo "서비스별 DB 생성 완료"
