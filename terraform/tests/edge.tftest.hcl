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
run "edge_private_origin" {
  command = plan
  module { source = "../modules/edge" }
  providers = { aws = aws, aws.us_east_1 = aws.us_east_1 }
  variables {
    name                 = "test"
    domain_name          = "test.example.com"
    hosted_zone_id       = "Z1234567890"
    frontend_bucket_name = "test-shoppinglive-frontend"
    origin_verify_secret = "synthetic-test-secret-not-real-0001"
    nlb_dns_name         = ""
  }
  assert {
    condition     = length(aws_route53_record.api_origin) == 0 && aws_s3_bucket_public_access_block.frontend.block_public_policy && aws_s3_bucket_public_access_block.frontend.restrict_public_buckets
    error_message = "빈 NLB 주소는 CNAME을 만들지 않고 S3 공개 접근을 차단해야 한다."
  }
  assert {
    condition     = aws_cloudfront_distribution.this.ordered_cache_behavior[0].viewer_protocol_policy == "https-only" && !aws_cloudfront_distribution.this.ordered_cache_behavior[0].compress && length(aws_cloudfront_distribution.this.ordered_cache_behavior[0].allowed_methods) == 7
    error_message = "API는 HTTPS와 모든 API 메서드를 지원하고 SSE 압축을 끈다."
  }
}
run "nlb_cloudfront_only" {
  command = plan
  module { source = "../modules/nlb" }
  variables {
    cluster_name = "test"
    vpc_id       = "vpc-00000000000000001"
    vpc_cidr     = "10.0.0.0/16"
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.from_cloudfront.from_port == 443 && aws_vpc_security_group_ingress_rule.from_cloudfront.to_port == 443 && data.aws_ec2_managed_prefix_list.cloudfront_origin_facing.name == "com.amazonaws.global.cloudfront.origin-facing" && aws_vpc_security_group_ingress_rule.from_cloudfront.cidr_ipv4 == null
    error_message = "NLB 443 인바운드는 CloudFront 관리형 IP 목록에 한정한다."
  }
}
