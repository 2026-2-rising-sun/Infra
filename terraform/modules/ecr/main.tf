# 서비스 5개의 컨테이너 이미지 저장소.
#
# 태그는 커밋 SHA 로 고정하고(IMMUTABLE) 같은 태그를 덮어쓰지 못하게 한다.
# GitOps 에서 "무엇이 배포됐나"를 추적하려면 태그가 바뀌지 않아야 한다. :latest 는 쓰지 않는다.
# 수명 주기 정책으로 최근 10개만 남겨 저장 비용(GB당 $0.10/월)을 묶어 둔다.

resource "aws_ecr_repository" "this" {
  for_each = toset(var.services)

  name                 = "${var.namespace}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # 환경을 지울 때 이미지가 남아 있어도 저장소를 지운다

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "최근 ${var.keep_images} 개만 유지"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.keep_images
      }
      action = { type = "expire" }
    }]
  })
}
