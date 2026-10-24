# NLB 자체는 여기서 만들지 않는다.
#
# 쿠버네티스에서 type: LoadBalancer Service 를 만들면 클러스터 안 AWS Load Balancer Controller 가
# 그 Service 에 맞는 NLB 를 만들고, Service 가 지워지면 NLB 도 지운다. Terraform 이 NLB 를 따로 만들면
# 타깃(Envoy 파드 IP)을 누가 갱신하느냐가 문제가 돼서 두 곳에서 관리하게 된다.
#
# 그래서 이 모듈은 컨트롤러가 일할 수 있는 조건만 만든다.
#   1. 컨트롤러 IAM 역할 (Pod Identity) — NLB·타깃 그룹·보안그룹 규칙을 만들 권한
#   2. NLB 에 붙일 보안그룹 — CloudFront 의 오리진 IP 대역(관리형 프리픽스 리스트)에서 오는 443 만 허용
# Service 쪽 어노테이션(어떤 보안그룹·인증서를 쓸지)은 platform/aws/envoy-gateway/ 에 있다.

data "aws_partition" "current" {}

# --- 컨트롤러 IAM ---------------------------------------------------------

data "aws_iam_policy_document" "controller_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "controller" {
  name               = "${var.cluster_name}-lb-controller"
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json
}

# 정책 파일은 컨트롤러 릴리스의 docs/install/iam_policy.json 을 그대로 둔 것이다. 버전을 올리면 같이 갱신한다.
resource "aws_iam_role_policy" "controller" {
  name   = "aws-load-balancer-controller"
  role   = aws_iam_role.controller.id
  policy = file("${path.module}/lb-controller-iam-policy.json")
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = var.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.controller.arn
}

# --- NLB 보안그룹 ------------------------------------------------------------

# CloudFront 가 오리진에 접속할 때 쓰는 IP 대역. AWS 가 관리하므로 대역이 바뀌어도 규칙을 안 고친다.
data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "nlb" {
  name        = "${var.cluster_name}-api-nlb"
  description = "API NLB. CloudFront 오리진 IP 에서 오는 443 만 허용"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.cluster_name}-api-nlb" }
}

resource "aws_vpc_security_group_ingress_rule" "from_cloudfront" {
  security_group_id = aws_security_group.nlb.id
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.id
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nlb.id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}
