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

mock_provider "aws" { alias = "us_east_1" }
run "dev_wiring" {
  command = plan
  variables {
    domain_name             = "test.example.com"
    hosted_zone_id          = "Z1234567890"
    bucket_suffix           = "test123456"
    origin_verify_secret    = "synthetic-test-secret-not-real-0001"
    budget_alert_email      = "test@example.com"
    eks_public_access_cidrs = ["192.0.2.1/32"]
  }
  assert {
    condition     = module.eks.cluster_name == "shoppinglive-dev" && module.edge.api_origin_hostname == "api-origin.test.example.com"
    error_message = "dev 루트의 EKS와 엣지 입력 연결을 유지해야 한다."
  }
}
