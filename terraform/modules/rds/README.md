# terraform/modules/rds

PostgreSQL 1대(db.t4g.small, 단일 AZ, 프라이빗). 서비스별 DB 5개는 같은 인스턴스 안에 만든다.

## 결정한 것

| 항목 | 결정 | 이유 |
|---|---|---|
| 인스턴스 수 | 1대, DB 5개 | 5대면 고정비 다섯 배. Backend dev 프로필이 이미 "같은 호스트, 다른 DB 이름" 구조다. 병목이면 그때 분리 |
| 비밀번호 | `manage_master_user_password` | RDS 가 Secrets Manager 에 직접 넣는다. 상태 파일·git 에 평문이 없다 |
| 백업 | 1일, 최종 스냅샷 없음 | 지우고 다시 만드는 환경. 데이터는 시드로 재생성 |
| Multi-AZ | 끔 | 두 배 비용. 가용성 실험 대상이 아니다 |
| 접근 | EKS 클러스터 보안그룹에서 오는 5432 만 | 노트북에서 직접 못 붙는다. DB 작업은 클러스터 안 파드로 |

## 서비스별 DB 만들기

`platform/aws/rds-init.sh` 가 클러스터 안 일회성 파드에서 `platform/aws/rds/init.sql` 을 실행한다. `platform/aws/install.sh` 의 마지막 단계에 포함돼 있다.
