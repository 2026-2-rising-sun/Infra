# local

로컬 개발용 미들웨어 스택. Backend 서비스는 호스트에서 직접 실행하고, 의존 미들웨어만 컨테이너로 띄운다.

```sh
cp local/.env.example local/.env     # 비밀번호 등 값 채우기
docker compose -f local/docker-compose.yml up -d
docker compose -f local/docker-compose.yml ps
```

내리기: `down`은 PostgreSQL·Redis 등의 이름 있는 볼륨을 남기고, `down -v`는 볼륨까지 삭제한다. 기본 Kafka에는 데이터 볼륨이 없어 컨테이너를 다시 만들면 메시지와 offset을 잃는다.

## 구성

| 컴포넌트 | 이미지 | 호스트 포트 |
|---|---|---|
| PostgreSQL | `postgres:16-alpine` | 5432 |
| Redis | `redis:7-alpine` | 6379 |
| Kafka (KRaft, Zookeeper 없음) | `apache/kafka:4.0.0` | 29092 |
| 가짜 토스페이먼츠 (WireMock) | `wiremock/wiremock:3.9.1` | 59080 |

Kafka 토픽은 `init/kafka/topics.tsv`와 `kafka-init`이 명시적으로 생성한다. 기존 알림·Live 토픽과 auto-create는 유지한다. Core Outbox CDC용 Connect는 선택 `cdc` 프로필이며 [구성·독립 검증·복구 절차](cdc/README.md)를 따른다. 독립 smoke는 기본 스택과 다른 project/포트/DB/볼륨을 사용한다.

## 데이터 보존과 설정 적용

이 Compose의 PostgreSQL은 `postgres-data` 볼륨을 사용한다. logical WAL 옵션 때문에 컨테이너를 재생성하더라도 같은 project·볼륨을 유지해야 기존 DB를 이어 쓸 수 있다. 적용 전 대상 볼륨과 백업·복원 가능 여부를 확인하고, DB를 추가하려고 `down -v`를 실행하지 않는다. 기존 볼륨에는 아래의 [빠진 DB만 생성하는 절차](#서비스별-db-생성)를 사용한다.

[개발 Kubernetes PostgreSQL](../k8s/README.md)은 이 Compose와 다르다. `Recreate` 전략과 Pod 수명의 임시 볼륨 `emptyDir`를 사용하므로, args·env 변경을 적용해 Pod가 교체되면 기존 DB 데이터와 복제 slot/WAL을 잃을 수 있다. 적용 전에 데이터 보존 필요성과 백업·복원 계획을 소유자와 확인한다. init 스크립트가 DB 이름을 다시 만드는 것은 업무 데이터 복구가 아니다.

Infra #58과 [Backend #379](https://github.com/2026-2-rising-sun/Backend/pull/379)의 병합만으로 실행 환경의 CDC가 활성화되지는 않는다. 실제 연결 전에는 [스키마·relay 제외·초기 적재와 connector 등록 순서](cdc/README.md#core-db와-connector-등록)를 확인한다. 이 안내는 실제 배포나 운영 연동 완료 기록이 아니다.

## 외부 서비스 Mock

외부 서비스 대신 응답하는 가짜 서버다. 기본 `up` 에 함께 뜬다. 응답 정의는 `mocks/<이름>/mappings/` 에 둔다.

### 토스페이먼츠 (`toss-mock`, `localhost:59080`)

Backend payment-service 를 `local` 프로필로 띄우면 결제 승인을 실제 토스 대신 여기로 보낸다. 실제 토스 테스트 환경은 Backend 를 `local,toss-real` 프로필로 띄울 때만 쓴다.

| 승인 요청의 paymentKey | 응답 |
|---|---|
| 아래 시나리오 키가 아닌 값 | 요청한 orderId·금액으로 승인(DONE) |
| `pk-ok` / `pk-decline` / `pk-retry` | 승인 / 거절(403) / 승인 |
| `pk-slow` | 12초 뒤 승인 |
| `pk-5xx` | 500 뒤 조회하면 승인 |
| `pk-mismatch` | 금액이 다른 승인 → Backend 가 보상 취소 |

시나리오 키는 orderId 회차 `-1`(`pk-retry` 만 `-2`) 기준이다. 시나리오별 순서와 기대 결과는 Backend `services/payment-service/local/README.md` 에 있다. 요청 기록은 `curl localhost:59080/__admin/requests` 로 보고 `curl -X DELETE localhost:59080/__admin/requests` 로 지운다. 응답 정의를 바꿨다면 `docker compose -f local/docker-compose.yml restart toss-mock`.

## 확인용 관리 UI (`tools` 프로필)

기본 `up` 에는 포함되지 않는다. Kafka 토픽이나 Redis 키를 눈으로 볼 때만 띄운다.

```sh
docker compose -f local/docker-compose.yml --profile tools up -d
```

| 도구 | 이미지 | 주소 |
|---|---|---|
| Kafka UI | `kafbat/kafka-ui:v1.5.0` | http://localhost:8090 |
| Redis Insight | `redis/redisinsight:3.8.0` | http://localhost:5540 |

- Kafka UI 는 `shoppinglive-local` 클러스터로 자동 연결된다.
- Redis Insight 는 처음 한 번 "Add Redis database" 에서 **Host `redis`, Port `6379`** 로 등록한다. `localhost` 가 아니다. 등록 정보는 볼륨에 남는다.
- 인증을 켜지 않았으므로 로컬에서만 쓴다.

내릴 때 `--profile tools` 를 빼고 `down` 하면 이 두 컨테이너는 남는다. 같이 내리려면 `--profile tools down`.

## Backend 연결 정보

**이 값들이 Backend·Infra 두 레포 간 유일한 실질적 연결점이다.** 여기를 바꾸면 Backend 각 서비스의
`application-local.yml` 도 같이 고쳐야 한다.

| 서비스 | DB 이름 | 로컬 실행 포트 |
|---|---|---|
| member-service | `member` | 8081 |
| catalog-service | `catalog` | 8082 |
| commercecore-service | `commercecore` | 8083 |
| live-service | `live` | 8084 |
| notification-service | `notification` | 8085 |
| payment-service | `payment` | 8086 |

`shopping`·`commerce`는 서비스 분리 전 Backend 커밋(shopping-service·commerce-service)용으로 남겨 둔다.

- JDBC URL: `jdbc:postgresql://localhost:5432/<db>` (계정은 모든 DB 공통, `.env` 의 `POSTGRES_USER`/`POSTGRES_PASSWORD`)
- Redis: `localhost:6379`
- Kafka bootstrap servers: `localhost:29092`
  컨테이너 **안에서** 붙을 때는 `kafka:9092` 다. 리스너가 둘로 나뉘어 있다.

> 서비스별 포트 8081~8086 은 여러 서비스를 한 호스트에 동시에 띄울 때 충돌을 피하기 위한 것이다.
> 쿠버네티스에서는 파드마다 주소가 달라 전부 8080 을 쓴다 (`k8s/README.md` 참고).

## 서비스별 DB 생성

`init/postgres/01-create-databases.sh` 가 `POSTGRES_MULTIPLE_DATABASES` 목록을 읽어 서비스별 DB 를 만든다.
**데이터 볼륨이 비어 있을 때만 실행된다.** 이미 볼륨이 있으면 `down -v`(모든 DB 데이터 삭제) 대신 빠진 DB 만 만든다.

```bash
for db in catalog commercecore payment; do
  docker exec shoppinglive-postgres psql -U "${POSTGRES_USER:-shoppinglive}" -tc "SELECT 1 FROM pg_database WHERE datname = '$db'" | grep -q 1 \
    || docker exec shoppinglive-postgres psql -U "${POSTGRES_USER:-shoppinglive}" -c "CREATE DATABASE \"$db\";"
done
```
