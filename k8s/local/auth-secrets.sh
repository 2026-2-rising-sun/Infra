#!/bin/sh
# kind 개발 namespace 에 서비스 기동용 인증 입력을 만든다.
#   - member JWT 서명 키(Secret member-jwt-private), 공개 키 JWKS(ConfigMap member-jwt-public), kid(ConfigMap member-auth-policy)
#   - 서비스 간 호출 토큰 8개(Secret <호출자>-<대상>-service-token, key=token)
# 이미 있는 리소스는 건드리지 않는다. 운영 환경 키를 만드는 스크립트가 아니다.
# 사용: sh k8s/local/auth-secrets.sh [namespace]   (기본 shoppinglive-dev)
set -eu
NS=${1:-shoppinglive-dev}
KUBECTL=${KUBECTL:-kubectl}

exists() { $KUBECTL -n "$NS" get "$1" "$2" >/dev/null 2>&1; }

$KUBECTL get namespace "$NS" >/dev/null 2>&1 || $KUBECTL create namespace "$NS"

if exists secret member-jwt-private; then
  echo "skip: member-jwt-private (이미 있음)"
else
  work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
  umask 077
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/member-private.pem" 2>/dev/null
  kid="kind-$(date +%Y%m%d)-$(openssl rand -hex 4)"
  n=$(openssl rsa -in "$work/member-private.pem" -noout -modulus | cut -d= -f2 \
    | python3 -c 'import sys,base64; print(base64.urlsafe_b64encode(bytes.fromhex(sys.stdin.read().strip())).decode().rstrip("="))')
  printf '{"keys":[{"kty":"RSA","e":"AQAB","n":"%s","kid":"%s","alg":"RS256","use":"sig"}]}\n' "$n" "$kid" > "$work/member-public.jwks"
  $KUBECTL -n "$NS" create secret generic member-jwt-private --from-file=member-private.pem="$work/member-private.pem"
  $KUBECTL -n "$NS" create configmap member-jwt-public --from-file=member-public.jwks="$work/member-public.jwks" --dry-run=client -o yaml | $KUBECTL apply -f -
  $KUBECTL -n "$NS" create configmap member-auth-policy --from-literal=key-id="$kid" --dry-run=client -o yaml | $KUBECTL apply -f -
fi

for pair in shopping-member commerce-member live-member notification-member \
            commerce-shopping live-shopping shopping-commerce live-commerce; do
  name="$pair-service-token"
  if exists secret "$name"; then
    echo "skip: $name (이미 있음)"
  else
    $KUBECTL -n "$NS" create secret generic "$name" --from-literal=token="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
  fi
done
