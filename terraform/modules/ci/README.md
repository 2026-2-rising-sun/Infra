# terraform/modules/ci

GitHub Actions 가 AWS 를 쓰기 위한 OIDC 공급자와 역할. 장기 액세스 키를 리포지토리 시크릿에 넣지 않는다.

권한은 세 가지뿐이다.

| 워크플로 | 권한 |
|---|---|
| Backend 이미지 빌드 | ECR 로그인 + 저장소 5개 푸시 |
| Frontend 배포 | S3 버킷 업로드·삭제 + CloudFront 무효화 |
| Infra | 없음. `terraform apply` 는 사람이 노트북에서 한다 |

워크플로 쪽 설정:

```yaml
permissions:
  id-token: write
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: <terraform output github_actions_role_arn>
      aws-region: ap-northeast-2
```

배포 신뢰 조건은 `github_refs`의 정확한 브랜치(default dev/main)만 허용한다. PR·임의 브랜치·GitHub Environment 토큰은 자동으로 허용하지 않는다. 배포 워크플로를 연결할 때 해당 브랜치 보호와 실제 OIDC 토큰을 별도로 검증한다.
