# CloudFront 인증서와 WAF(CLOUDFRONT 범위)는 us-east-1 에만 만들 수 있어서 두 번째 provider 를 받는다.
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.us_east_1]
    }
  }
}
