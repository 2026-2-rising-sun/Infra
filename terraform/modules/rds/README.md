# terraform/modules/rds

서비스별 PostgreSQL 데이터베이스를 정의할 모듈.

**상태: 향후 정의.** 팀이 AWS 사용 범위를 합의한 뒤 채운다.

채울 때 최소한 다음을 결정해야 한다.

- 인스턴스를 서비스마다 분리할지, 한 인스턴스에 DB만 분리할지
  (로컬은 `local/docker-compose.yml` 단일 컨테이너 + 다중 DB 구성이지만 클라우드는 별개 결정)
- 인스턴스 클래스, 스토리지, 백업 보존 기간, Multi-AZ 여부
- 자격증명 관리 방식 (Secrets Manager / SSM Parameter Store)
