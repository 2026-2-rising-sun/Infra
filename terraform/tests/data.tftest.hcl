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

run "rds_private" {
  command = plan
  module { source = "../modules/rds" }
  variables {
    name                     = "test"
    vpc_id                   = "vpc-00000000000000001"
    private_subnet_ids       = ["subnet-00000000000000001", "subnet-00000000000000002"]
    source_security_group_id = "sg-00000000000000001"
  }
  assert {
    condition     = !aws_db_instance.this.publicly_accessible && aws_db_instance.this.storage_encrypted && aws_db_instance.this.manage_master_user_password
    error_message = "RDS는 비공개·암호화·관리형 마스터 비밀번호를 유지해야 한다."
  }
}
run "ecr_immutable" {
  command = plan
  module { source = "../modules/ecr" }
  assert {
    condition     = length(aws_ecr_repository.this) == 5 && alltrue([for repo in aws_ecr_repository.this : repo.image_tag_mutability == "IMMUTABLE"])
    error_message = "서비스별 저장소 5개는 태그 덮어쓰기를 막아야 한다."
  }
}
run "ci_trusted_branches" {
  command = plan
  module { source = "../modules/ci" }
  variables {
    name                        = "test"
    ecr_repository_arns         = ["arn:aws:ecr:ap-northeast-2:123456789012:repository/test"]
    frontend_bucket_arn         = "arn:aws:s3:::test-frontend"
    cloudfront_distribution_arn = "arn:aws:cloudfront::123456789012:distribution/TEST"
  }
  assert {
    condition     = alltrue(flatten([for s in data.aws_iam_policy_document.assume.statement : [for c in s.condition : c.variable != "token.actions.githubusercontent.com:sub" || (c.test == "StringEquals" && alltrue([for v in c.values : !strcontains(v, "*") && strcontains(v, ":ref:refs/heads/")]))]]))
    error_message = "OIDC sub는 정확한 배포 브랜치만 허용해야 한다."
  }
}
