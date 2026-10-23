# terraform/modules/ecr

서비스 5개의 이미지 저장소 `shoppinglive/<service>`. 태그는 커밋 SHA 로 고정(IMMUTABLE), 최근 10개만 유지, 푸시 시 취약점 스캔.

`:latest` 를 쓰지 않는 이유: GitOps 에서 "무엇이 배포됐나"는 kustomize `images` 의 태그로 추적한다. 태그가 바뀌지 않아야 그 기록이 의미가 있다.
