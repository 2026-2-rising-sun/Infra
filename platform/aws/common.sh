#!/usr/bin/env bash
# 실행한 프로세스와 자식에서만 쓰는 접속 설정. 사용자 kubeconfig/Helm 설정은 바꾸지 않는다.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TF_DIR="$ROOT/terraform/envs/dev"
export APP_NAMESPACE=${APP_NAMESPACE:-shoppinglive-dev}
tf_out() { terraform -chdir="$TF_DIR" output -raw "$1"; }

aws_context() {
  CLUSTER_NAME=$(tf_out cluster_name)
  AWS_REGION=$(tf_out aws_region)
  local expected actual
  expected=$(tf_out cluster_arn)
  actual=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --query cluster.arn --output text)
  [ "$expected" = "$actual" ] || { echo 'Terraform 대상과 AWS 클러스터가 다릅니다.' >&2; return 1; }
  AWS_WORK_DIR=$(mktemp -d)
  trap 'rm -rf "$AWS_WORK_DIR"' EXIT
  export KUBECONFIG="$AWS_WORK_DIR/kubeconfig"
  export HELM_CONFIG_HOME="$AWS_WORK_DIR/helm/config" HELM_CACHE_HOME="$AWS_WORK_DIR/helm/cache" HELM_DATA_HOME="$AWS_WORK_DIR/helm/data"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG" >/dev/null
}
