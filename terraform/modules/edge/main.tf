# 엣지: S3(정적 파일) + CloudFront + WAF + ACM + Route 53.
#
# 요청 흐름
#   브라우저 → Route 53 → CloudFront(WAF)
#     /api/*  → NLB(api-origin.<도메인>) → Envoy Gateway        캐시 없음, Authorization 헤더 전달
#     /*      → S3 (OAC)                                       캐시, SPA 경로는 CloudFront Function 이 index.html 로
#
# NLB 는 Terraform 이 만들지 않는다. 클러스터 안 AWS Load Balancer Controller 가 Envoy Gateway 의 Service 를 보고
# 만든다(modules/nlb 참고). 그래서 CloudFront 오리진은 NLB 주소를 직접 가리키지 않고
# 우리 도메인의 CNAME(api-origin.<도메인>)을 가리킨다. NLB 가 생긴 뒤 nlb_dns_name 변수에 주소를 넣고
# apply 하면 CNAME 만 바뀌고 CloudFront 는 그대로다.
#
# 인증서는 두 장이다. CloudFront 는 반드시 us-east-1 의 인증서만 받고, NLB TLS 리스너는 서울 인증서를 쓴다.

locals {
  api_origin_hostname = coalesce(var.api_origin_hostname, "api-origin.${var.domain_name}")
}

# --- S3 (정적 파일, 비공개) -----------------------------------------------

resource "aws_s3_bucket" "frontend" {
  bucket        = var.frontend_bucket_name
  force_destroy = true # 환경을 지울 때 빌드 결과가 남아 있어도 버킷을 지운다
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# OAC: CloudFront 가 S3 요청에 SigV4 서명을 붙이고, 버킷 정책은 "이 배포에서 온 서명"만 허용한다.
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.name}-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "frontend_bucket" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# --- 인증서 ---------------------------------------------------------------

# CloudFront 용. us-east-1 에만 둘 수 있다.
resource "aws_acm_certificate" "edge" {
  provider = aws.us_east_1

  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "edge_validation" {
  for_each = {
    for dvo in aws_acm_certificate.edge.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "edge" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.edge.arn
  validation_record_fqdns = [for r in aws_route53_record.edge_validation : r.fqdn]
}

# NLB TLS 리스너용. 서울 리전.
resource "aws_acm_certificate" "origin" {
  domain_name       = local.api_origin_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "origin_validation" {
  for_each = {
    for dvo in aws_acm_certificate.origin.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "origin" {
  certificate_arn         = aws_acm_certificate.origin.arn
  validation_record_fqdns = [for r in aws_route53_record.origin_validation : r.fqdn]
}

# --- WAF (CloudFront 범위는 us-east-1 에 만든다) ---------------------------

resource "aws_wafv2_web_acl" "this" {
  provider = aws.us_east_1

  name  = "${var.name}-edge"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # 관리형 룰셋 3개. 순서(priority)대로 평가하고, 룰셋 안의 차단은 그대로 둔다(override_action none).
  dynamic "rule" {
    for_each = {
      1 = "AWSManagedRulesCommonRuleSet"
      2 = "AWSManagedRulesKnownBadInputsRuleSet"
      3 = "AWSManagedRulesSQLiRuleSet"
    }

    content {
      name     = rule.value
      priority = rule.key

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value
        sampled_requests_enabled   = true
      }
    }
  }

  # IP 당 5분에 rate_limit 건을 넘으면 차단. 부하 테스트 IP 는 한도 안에서 돌리거나 임시로 올린다.
  rule {
    name     = "RateLimitPerIp"
    priority = 10

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitPerIp"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-edge"
    sampled_requests_enabled   = true
  }
}

# --- CloudFront -----------------------------------------------------------

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# SPA 는 /broadcasts/3 같은 경로도 index.html 이 처리한다. S3 에는 그런 파일이 없으므로
# 확장자 없는 경로를 index.html 로 바꿔 보낸다. OAC 는 S3 REST 엔드포인트만 지원해 정적 웹사이트 호스팅의
# 오류 문서 기능을 못 쓰기 때문에 이 함수가 필요하다. /api/* 는 다른 behavior 라 이 함수를 타지 않는다.
resource "aws_cloudfront_function" "spa_rewrite" {
  name    = "${var.name}-spa-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = file("${path.module}/spa-rewrite.js")
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${var.name} frontend + api"
  aliases         = [var.domain_name]
  price_class     = var.price_class
  web_acl_id      = aws_wafv2_web_acl.this.arn
  http_version    = "http2and3"

  origin {
    origin_id                = "s3-frontend"
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  origin {
    origin_id   = "nlb-api"
    domain_name = local.api_origin_hostname

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
      # SSE 는 heartbeat 15초라 60초면 끊기지 않는다. 60초가 별도 한도 상향 없이 쓸 수 있는 최대값이다.
      origin_read_timeout      = 60
      origin_keepalive_timeout = 60
    }

    # NLB 로 직접 들어오는 요청을 Envoy 가 거를 수 있게 비밀 헤더를 붙인다. 값은 상태 파일에만 있고 git 에는 없다.
    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_verify_secret
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa_rewrite.arn
    }
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    target_origin_id         = "nlb-api"
    viewer_protocol_policy   = "https-only"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    compress                 = false # SSE 스트림은 압축하면 버퍼링된다
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.edge.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# --- Route 53 ---------------------------------------------------------------

resource "aws_route53_record" "apex" {
  for_each = toset(["A", "AAAA"])

  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = each.value

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

# NLB 가 생긴 뒤에만 만들어진다. 그 전엔 /api/* 가 CloudFront 에서 502 로 떨어진다.
resource "aws_route53_record" "api_origin" {
  count = var.nlb_dns_name == null ? 0 : 1

  zone_id = var.hosted_zone_id
  name    = local.api_origin_hostname
  type    = "CNAME"
  ttl     = 60
  records = [var.nlb_dns_name]
}
