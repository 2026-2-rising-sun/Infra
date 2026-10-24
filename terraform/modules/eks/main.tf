# EKS 클러스터 + 시스템 노드 그룹 + 애드온.
#
# 노드는 두 종류로 나눈다.
#   - 시스템 노드 그룹(이 모듈): 2대 고정. Karpenter 컨트롤러·ArgoCD·Envoy Gateway·CoreDNS 처럼
#     "노드를 만들어 주는 쪽"과 클러스터 기본 부품이 올라간다. Karpenter 가 자기 자신을 띄울 수는 없어서 필요하다.
#   - 앱 노드(modules/karpenter): Karpenter 가 Pending 파드를 보고 필요할 때 만들고 회수한다.
#
# 인증은 EKS Access Entry(API) 방식만 쓴다. aws-auth ConfigMap 을 손으로 고치는 옛 방식은 쓰지 않는다.
# 클러스터를 만든 IAM 주체는 자동으로 관리자가 된다(bootstrap_cluster_creator_admin_permissions).
#
# 파드 권한은 IRSA 가 아니라 Pod Identity 로 준다. OIDC 공급자 등록이 필요 없고,
# 역할 신뢰 정책이 pods.eks.amazonaws.com 하나로 끝나서 모듈이 단순해진다.

data "aws_partition" "current" {}

# --- 클러스터 IAM ---------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# --- 클러스터 -------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    # 노트북에서 kubectl 을 바로 쓰려고 퍼블릭 엔드포인트를 연다. 접근 IP 는 변수로 좁힌다.
    endpoint_public_access = true
    public_access_cidrs    = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # 표준 지원 기간이 끝나면 시간당 $0.10 → $0.60 으로 오른다. 연장 지원으로 자동 전환되지 않게 막고,
  # 지원 종료 전에 버전을 올리는 쪽을 택한다.
  upgrade_policy {
    support_type = "STANDARD"
  }

  # 기본 애드온(vpc-cni, kube-proxy, coredns)을 "관리되지 않는" 형태로 깔지 않고 아래 aws_eks_addon 으로 직접 관리한다.
  bootstrap_self_managed_addons = false

  enabled_cluster_log_types = var.cluster_log_types

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# Karpenter 가 노드에 붙일 보안그룹을 찾을 때 쓰는 태그. 클러스터가 만든 기본 보안그룹에 붙인다.
resource "aws_ec2_tag" "cluster_sg_discovery" {
  resource_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# --- 시스템 노드 그룹 -----------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-system-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  version         = var.kubernetes_version

  # Graviton(arm64) 가 같은 성능에서 x86 보다 20% 쯤 싸다. 앱 이미지도 arm64 로 빌드한다.
  ami_type       = "AL2023_ARM_64_STANDARD"
  instance_types = var.system_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.system_node_count
    min_size     = var.system_node_count
    max_size     = var.system_node_count + 1
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    "shoppinglive.io/node-role" = "system"
  }

  depends_on = [aws_iam_role_policy_attachment.node]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# --- 애드온 ---------------------------------------------------------------
#
# 버전을 고정하지 않고 "이 클러스터 버전에서 가장 최신" 을 데이터 소스로 고른다.
# 고정하면 클러스터 버전을 올릴 때마다 다섯 줄을 같이 고쳐야 하는데, 애드온은 호환 범위 안에서 최신이 안전하다.

locals {
  # coredns 는 노드가 있어야 뜬다. vpc-cni·kube-proxy·pod-identity-agent 는 DaemonSet 이라 노드 그룹보다 먼저 만들어도 된다.
  addons_before_nodes = ["vpc-cni", "kube-proxy", "eks-pod-identity-agent"]
  addons_after_nodes  = ["coredns", "aws-ebs-csi-driver"]
}

data "aws_eks_addon_version" "this" {
  for_each = toset(concat(local.addons_before_nodes, local.addons_after_nodes))

  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.this.version
  most_recent        = true
}

resource "aws_eks_addon" "before_nodes" {
  for_each = toset(local.addons_before_nodes)

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = data.aws_eks_addon_version.this[each.value].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = data.aws_eks_addon_version.this["coredns"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system, aws_eks_addon.before_nodes]
}

# EBS CSI 는 볼륨을 만들 IAM 권한이 필요하다. 애드온 자체가 Pod Identity 연결을 받는다.
data "aws_iam_policy_document" "pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = data.aws_eks_addon_version.this["aws-ebs-csi-driver"].version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi.arn
    service_account = "ebs-csi-controller-sa"
  }

  depends_on = [aws_eks_node_group.system, aws_eks_addon.before_nodes]
}
