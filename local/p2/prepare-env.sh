#!/bin/sh
set -eu
umask 077
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target=${1:-"$script_dir/.env"}
if [ -e "$target" ]; then
  printf '%s\n' "Refusing to overwrite existing environment: $target" >&2
  exit 1
fi
password=$(openssl rand -hex 32)
# noclobber also prevents a race from replacing an existing regular file.
(set -C; printf '%s\n' 'P2_POSTGRES_PORT=15432' "P2_POSTGRES_PASSWORD=$password" > "$target")
printf '%s\n' "Created private local environment: $target"
