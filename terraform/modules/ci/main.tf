# GitHub Actions 가 장기 액세스 키 없이 AWS 를 쓰기 위한 OIDC 연결.
#
# Actions 는 실행마다 GitHub 이 서명한 짧은 토큰을 받고, AWS 는 그 토큰을 믿고 역할을 빌려준다.
# 리포지토리 시크릿에 AWS 키를 넣는 방식은 키가 새면 끝이라 쓰지 않는다.
# 신뢰 조건의 sub 는 지정한 저장소의 배포 브랜치로 제한해 PR 토큰과 임의 브랜치가 배포 권한을 받지 못하게 한다.

data "aws_partition" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS 는 GitHub OIDC 의 인증서 체인을 자체 신뢰 저장소로 검증하므로 지문 값은 형식만 맞으면 된다.
  thumbprint_list = ["ffffffffffffffffffffffffffffffffffffffff"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = flatten([for repo in var.github_repositories : [for ref in var.github_refs : "repo:${repo}:ref:${ref}"]])
    }
  }
}

resource "aws_iam_role" "actions" {
  name               = "${var.name}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# 권한은 세 가지만: ECR 푸시(Backend), S3 업로드 + CloudFront 무효화(Frontend). Infra 의 terraform apply 는 사람이 한다.
data "aws_iam_policy_document" "actions" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }

  statement {
    sid       = "FrontendBucketList"
    actions   = ["s3:ListBucket"]
    resources = [var.frontend_bucket_arn]
  }

  statement {
    sid       = "FrontendBucketWrite"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${var.frontend_bucket_arn}/*"]
  }

  statement {
    sid       = "CloudFrontInvalidate"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [var.cloudfront_distribution_arn]
  }
}

resource "aws_iam_role_policy" "actions" {
  name   = "deploy"
  role   = aws_iam_role.actions.id
  policy = data.aws_iam_policy_document.actions.json
}
