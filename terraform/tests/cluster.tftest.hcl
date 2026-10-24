# AWS API를 호출하지 않고 각 실제 모듈의 계획을 검증한다.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-northeast-2" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}

run "network" {
  command = plan
  module { source = "../modules/network" }
  variables {
    name         = "test"
    cluster_name = "test"
    aws_region   = "ap-northeast-2"
  }
  assert {
    condition     = aws_subnet.public[0].cidr_block != aws_subnet.private[0].cidr_block && length(aws_subnet.private) == 2
    error_message = "공개·비공개 서브넷은 중복 없이 두 AZ에 구성되어야 한다."
  }
}
run "eks" {
  command = plan
  module { source = "../modules/eks" }
  variables {
    cluster_name        = "test"
    kubernetes_version  = "1.35"
    private_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_access_cidrs = ["192.0.2.1/32"]
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API" && aws_eks_cluster.this.vpc_config[0].public_access_cidrs == toset(["192.0.2.1/32"])
    error_message = "클러스터는 API 인증과 지정한 접근 CIDR을 사용해야 한다."
  }
}
run "karpenter" {
  command = plan
  module { source = "../modules/karpenter" }
  variables {
    cluster_name = "test"
    cluster_arn  = "arn:aws:eks:ap-northeast-2:123456789012:cluster/test"
  }
  assert {
    condition     = aws_sqs_queue.interruption.sqs_managed_sse_enabled && aws_eks_access_entry.node.type == "EC2_LINUX"
    error_message = "중단 큐 암호화와 Karpenter 노드 접근 등록이 필요하다."
  }
}

run "reject_public_cluster_api" {
  command = plan
  module { source = "../modules/eks" }
  variables {
    cluster_name        = "test"
    kubernetes_version  = "1.35"
    private_subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
    public_access_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.public_access_cidrs]
}
