#!/bin/sh
set -eu
umask 077
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
target=${1:-"$script_dir/.env"}
if [ -e "$target" ]; then
  printf '%s\n' "기존 환경 파일 덮어쓰기 거부: $target" >&2
  exit 1
fi
password=$(openssl rand -hex 32)
# noclobber는 동시 실행으로 기존 일반 파일을 덮어쓰는 것도 막는다.
(set -C; printf '%s\n' 'P2_POSTGRES_PORT=15432' "P2_POSTGRES_PASSWORD=$password" > "$target")
printf '%s\n' "비공개 로컬 환경 파일 생성 완료: $target"
