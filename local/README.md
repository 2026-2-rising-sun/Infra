# local

로컬 개발용 미들웨어 스택. Backend 서비스는 호스트에서 직접 실행하고, 의존 미들웨어만 컨테이너로 띄운다.

```sh
cp local/.env.example local/.env     # 비밀번호 등 값 채우기
docker compose -f local/docker-compose.yml up -d
docker compose -f local/docker-compose.yml ps
```

내리기: `down` (데이터 유지) / `down -v` (볼륨까지 삭제).

## 구성

| 컴포넌트 | 이미지 | 호스트 포트 |
|---|---|---|
| PostgreSQL | `postgres:16-alpine` | 5432 |
| Redis | `redis:7-alpine` | 6379 |
| Kafka (KRaft, Zookeeper 없음) | `apache/kafka:4.0.0` | 29092 |

## Backend 연결 정보

**이 값들이 Backend·Infra 두 레포 간 유일한 실질적 연결점이다.** 여기를 바꾸면 Backend 각 서비스의
`application-local.yml` 도 같이 고쳐야 한다.

| 서비스 | DB 이름 | 로컬 실행 포트 |
|---|---|---|
| member-service | `member` | 8081 |
| shopping-service | `shopping` | 8082 |
| commerce-service | `commerce` | 8083 |
| live-service | `live` | 8084 |
| notification-service | `notification` | 8085 |

- JDBC URL: `jdbc:postgresql://localhost:5432/<db>` (계정은 5개 DB 공통, `.env` 의 `POSTGRES_USER`/`POSTGRES_PASSWORD`)
- Redis: `localhost:6379`
- Kafka bootstrap servers: `localhost:29092`
  컨테이너 **안에서** 붙을 때는 `kafka:9092` 다. 리스너가 둘로 나뉘어 있다.

> 서비스별 포트 8081~8085 는 5개를 한 호스트에 동시에 띄울 때 충돌을 피하기 위한 것이다.
> 쿠버네티스에서는 파드마다 주소가 달라 전부 8080 을 쓴다 (`k8s/README.md` 참고).

## 서비스별 DB 생성

`init/postgres/01-create-databases.sh` 가 `POSTGRES_MULTIPLE_DATABASES` 목록을 읽어 DB 5개를 만든다.
**데이터 볼륨이 비어 있을 때만 실행된다.** DB 목록을 바꿨다면 `down -v` 로 볼륨을 지우고 다시 올려야 반영된다.
