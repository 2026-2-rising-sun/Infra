# Karpenter 가 동작하는 데 필요한 AWS 쪽 자원.
#
# Karpenter 자체(컨트롤러 파드)는 Helm 으로 클러스터 안에 설치한다(platform/aws/install.sh).
# 여기서는 컨트롤러가 EC2 를 만들고 지우는 권한, 노드가 클러스터에 합류하는 권한,
# 스팟 중단 예고를 받을 SQS 큐를 만든다. NodePool·EC2NodeClass 는 platform/aws/karpenter/ 의 YAML 이다.
#
# 노드 역할을 시스템 노드 그룹과 따로 둔 이유: Karpenter 노드는 EC2NodeClass 의 role 로 지정되는데,
# 역할 하나를 공유하면 나중에 한쪽만 권한을 바꿀 수 없다.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  partition = data.aws_partition.current.partition
  region    = data.aws_region.current.region
}

# --- 노드 역할 (Karpenter 가 만드는 EC2 가 쓴다) ------------------------------

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
  name               = "${var.cluster_name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# API 인증 모드에서는 노드 역할도 Access Entry 로 등록해야 kubelet 이 클러스터에 합류한다.
resource "aws_eks_access_entry" "node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.node.arn
  type          = "EC2_LINUX"
}

# --- 중단 예고 큐 ----------------------------------------------------------
#
# 스팟 회수 2분 전 경고, 리밸런스 권고, 예정된 점검, 인스턴스 상태 변화를 EventBridge 가 이 큐로 보내고
# Karpenter 가 읽어서 파드를 먼저 옮긴다. 큐가 없으면 스팟이 그냥 끊긴다.

resource "aws_sqs_queue" "interruption" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "interruption_queue" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.interruption.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.id
  policy    = data.aws_iam_policy_document.interruption_queue.json
}

locals {
  interruption_events = {
    scheduled_change = {
      source      = ["aws.health"]
      detail_type = ["AWS Health Event"]
    }
    spot_interruption = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Spot Instance Interruption Warning"]
    }
    rebalance = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance Rebalance Recommendation"]
    }
    instance_state_change = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance State-change Notification"]
    }
  }
}

resource "aws_cloudwatch_event_rule" "interruption" {
  for_each = local.interruption_events

  name = "${var.cluster_name}-karpenter-${replace(each.key, "_", "-")}"
  event_pattern = jsonencode({
    source      = each.value.source
    detail-type = each.value.detail_type
  })
}

resource "aws_cloudwatch_event_target" "interruption" {
  for_each = local.interruption_events

  rule = aws_cloudwatch_event_rule.interruption[each.key].name
  arn  = aws_sqs_queue.interruption.arn
}

# --- 컨트롤러 역할 (Pod Identity) -------------------------------------------

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
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.controller_assume.json
}

resource "aws_iam_role_policy" "controller" {
  name = "karpenter"
  role = aws_iam_role.controller.id
  policy = templatefile("${path.module}/controller-policy.json.tftpl", {
    partition     = local.partition
    region        = local.region
    account_id    = data.aws_caller_identity.current.account_id
    cluster_name  = var.cluster_name
    node_role_arn = aws_iam_role.node.arn
    queue_arn     = aws_sqs_queue.interruption.arn
    cluster_arn   = var.cluster_arn
  })
}

resource "aws_eks_pod_identity_association" "controller" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.controller.arn
}
