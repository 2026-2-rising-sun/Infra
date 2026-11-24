# Core Outbox → Catalog CDC

Core `public.event_outbox`의 `topic = commerce.catalog.snapshots.v1` INSERT와 최초 snapshot만 Kafka로 전달한다. 원본 상품/SKU 테이블, `payment_delivery_request`, 환불·결제·알림·Live 행은 발행하지 않는다. Core의 일반 relay와 lease/claim relay에서 이 Catalog 토픽을 제외한 **Backend 변경과 함께** 사용한다. CDC 장애를 relay fallback으로 처리하지 않는다.

[Infra #58](https://github.com/2026-2-rising-sun/Infra/pull/58)은 `main`, [Backend #379](https://github.com/2026-2-rising-sun/Backend/pull/379)는 `dev`에 병합됐다. 아래는 실행 환경별로 적용해야 하는 절차이며, 병합을 connector 등록·실제 배포·운영 연동 완료로 해석하지 않는다. 기존 독립 로컬 검증의 범위는 해당 PR의 검증 기록을 따른다.

## 토픽과 메시지

`../init/kafka/topics.tsv`가 로컬 목록이며 `k8s/overlays/dev/datatier/kafka.yaml`과 검사한다. 새 업무 토픽은 `commerce.catalog.snapshots.v1`(6 partitions), `commerce.refund.requests.v1`, `payment.refund.results.v1`, `payment.execution.results.v1`(각 3 partitions)이다. 환불 요청을 처리하지 못하면 Payment가 `commerce.refund.requests.v1.payment.dlt`로, 결제·환불 결과를 처리하지 못하면 CommerceCore가 `payment.execution.results.v1.commercecore.dlt`·`payment.refund.results.v1.commercecore.dlt`로 보낸다(각 3 partitions, 보관 30일 `retention.ms=2592000000`). DLT 유입 알림은 [`observability/local/alerts.yml`](../../observability/local/alerts.yml)의 `PaymentDltMessageArrived`다. 기존 `commerce.payment-group.v1`, `commerce.coupon-info.v1`, `commerce.sales-info.v1`, `live.broadcast.v1`은 유지한다. 새 쿠폰 동기화 토픽은 없다. 기존 토픽 삭제·이름 변경과 전역 auto-create 비활성화는 하지 않는다.

단일 broker에서 모든 replica는 1이다. Connect config/offset/status 토픽은 각각 1 partition, replica 1, `cleanup.policy=compact`로 명시한다. 여러 broker로 확장할 때 업무 토픽뿐 아니라 내부 토픽·worker replication factor·min ISR을 함께 검토한다. 로컬 1 broker의 복구 검증은 운영 HA 증명이 아니다. `bootstrap.sh`는 `--if-not-exists`로 생성하며 기존 partition·cleanup 설정은 변경하지 않는다. `topics.tsv` 5번째 열(`retention.ms`, `-`는 브로커 기본값)에 값이 있는 토픽만 매번 `kafka-configs.sh --alter`로 보관 기간을 맞추므로 이미 있던 DLT에도 30일이 반영된다. 그 밖의 설정이 다르면 describe 결과를 확인하고 별도 변경한다. auto-create로 먼저 생긴 토픽은 partition 수가 브로커 기본값으로 남으므로 DLT 토픽은 Backend 배포 전에 만든다.

| Core column | Kafka |
|---|---|
| `topic` | 목적 토픽(필터는 Catalog 하나만 허용) |
| `message_key` | UTF-8 문자열 key (`product:{id}` / `sku:{id}`) |
| `payload` TEXT | 기존 JSON 봉투 전체의 UTF-8 bytes |
| `event_id` / `event_type` | UTF-8 `eventId` / `eventType` headers |

Debezium EventRouter가 기본 `id` header도 추가한다. 호환 header `eventId`/`eventType`은 별도로 보낸다. 본문에는 header나 Debezium wrapper를 추가하지 않는다. `table.expand.json.payload=false`와 StringConverter를 함께 사용해 재직렬화·이중 인코딩 없이 TEXT 그대로 보낸다. `created_at`은 그대로 테이블에 두며 Kafka timestamp는 Debezium 처리 시간이다. `timestamptz`를 EventRouter timestamp 필드로 지정하지 않는다.

`catalogOnly` Groovy Filter → `outbox` EventRouter 순서를 고정한다. `c`/`r`와 정확한 topic만 통과시켜, 비대상 행은 EventRouter의 필드/schema 검증 이전에 버린다. publication도 해당 테이블의 INSERT만 발행한다. Filter SMT는 connector 기본 archive에 포함되지 않아, 이미지가 Debezium scripting 3.3.2와 Groovy 4.0.28의 `groovy`·`groovy-jsr223` jar를 checksum으로 고정해 설치한다. Connect API는 loopback에만 열며 인증 없는 외부 노출을 금한다.

공식 근거: [Debezium filtering](https://debezium.io/documentation/reference/3.3/transformations/filtering.html), [Outbox Event Router](https://debezium.io/documentation/reference/3.3/transformations/outbox-event-router.html), [PostgreSQL connector와 WAL](https://debezium.io/documentation/reference/3.3/connectors/postgresql.html). 선택 버전 소스: [3.3.2 EventRouterDelegate](https://github.com/debezium/debezium/blob/v3.3.2.Final/debezium-core/src/main/java/io/debezium/transforms/outbox/EventRouterDelegate.java).

## 독립 smoke 실행

Compose 2.24.4 이상(`!reset`/`!override` 지원), Docker, Python 3, kubectl이 필요하다. 검증한 Compose CLI는 v5.5.0이다. 외부 jar와 이미지 다운로드에 네트워크가 필요하다. 공용 `shoppinglive-local`이나 kind 클러스터를 중단하지 않는다.

```sh
python3 -m unittest discover -s local/cdc -p 'test_*.py' -v
python3 local/cdc/smoke.py --project kafka-cdc-smoke-my-run \
  --report .local-current/cdc/smoke-result.json
```

기본 독립 포트는 PostgreSQL `15432`, Kafka `39092`, Connect `18083`이다. 이미 점유되면 아래처럼 변경한다. 매 실행마다 새 project를 사용한다. 같은 isolated broker 안에서는 실제 목표 토픽명을 사용하고 group은 실행별로 고유하다.

```sh
CDC_POSTGRES_PORT=25432 CDC_KAFKA_PORT=49092 CDC_CONNECT_PORT=28083 \
  python3 local/cdc/smoke.py --project kafka-cdc-smoke-another-run \
  --connect-url http://127.0.0.1:28083 --report .local-current/cdc/another.json
```

smoke는 `smoke-schema.sql`로 최소한의 Infra fixture 테이블만 만든다. **Backend Flyway/실제 앱 발행·소비 또는 실제 PG 검증이 아니다.** 임의 `InfraSmokeSnapshot` 봉투를 사용하며, 정확한 신규 도메인 이벤트 fixture와 Core → CDC → Catalog 최종 검증은 통합 담당자가 수행한다. 이 스크립트를 실제 앱 DB에 실행하지 않는다.

계약 담당자의 예시를 같은 독립 connector에 추가로 넣어 원문·key·headers를 검사할 수 있다. `--examples` 폴더는 읽기만 하며 Backend 코드를 수정하지 않는다. 정확한 세 예시를 전송해도 실제 앱이 이 이벤트를 발행/소비했다는 증거는 아니다. 고정 eventId 예시는 새 project에서 한 번만 실행한다.

```sh
python3 local/cdc/verify-fixtures.py --project kafka-cdc-smoke-my-run \
  --examples /path/to/event-contracts/docs/worklog/plans/active/2026-11-event-contracts/examples \
  --report .local-current/cdc/contract-fixtures.json
```

실제 producer → EventOutbox 직렬화 표본은 `--manifest /path/to/build/cdc-handoff/manifest.json --source-root /path/to/producer-repo`를 추가한다. 도구가 표본 bytes SHA와 현재 producer source SHA를 모두 manifest와 대조하며, 바뀌었으면 새 manifest를 요청하도록 실패한다. 결과에는 manifest SHA·표본/소스 SHA·원본 생성 명령과 그 생성 경로의 대역 범위를 기록한다. 이 검사는 해당 bytes의 실제 PostgreSQL INSERT → Connect → Kafka 전송을 증명하며, 표본 생성 시의 H2/Mockito 대역을 PostgreSQL 업무 트랜잭션이나 실제 앱 발행·소비 증거로 바꾸지 않는다.

확인 항목은 bootstrap 두 번의 멱등성·14개 토픽 설정, Connect config validation/등록, 최초 snapshot과 streaming INSERT, key/봉투 원문/headers, 비대상 7개 토픽·HTTP 테이블 미발행, relay UPDATE/DELETE 미발행, Connect 중단 중 INSERT 후 복구, broker 재시작 후 복구, slot/WAL 진단이다. 비대상 미발행은 후속 Catalog INSERT를 WAL barrier로 삼아 검사한다. 실제 이미지 jar로 `FilterOrderSmoke.java`를 실행해 필수 payload 필드가 없는 비대상 행이 Filter에서 먼저 제거되고 역순이면 EventRouter schema 오류가 나는 것도 확인한다. 비영 종료·timeout·실패를 성공으로 처리하지 않는다.

검증 뒤 컨테이너와 볼륨은 남는다. 확인 후 **본인이 만든 project만** 정리한다. `-v`는 사용하지 않는다.

```sh
docker compose -p kafka-cdc-smoke-my-run -f local/cdc/docker-compose.yml ps -a
docker compose -p kafka-cdc-smoke-my-run -f local/cdc/docker-compose.yml down
```

## 실제 로컬 앱 연결

### 별도 Lima Docker 사용

Desktop 공용 VM에 자원 여유가 없다면 승인된 독립 Lima `shoppinglive-cdc` VM을 사용한다. VZ/aarch64, 4 CPU/6 GiB/30 GiB이며 Infra 작업공간과 Backend 작업공간은 읽기 전용 mount다. 기존 VM·Docker Desktop 설정·기본 context를 바꾸지 않는다. 모든 Docker/Compose/검증 호출에 아래 환경을 명시한다. Python 검증 도구의 Docker subprocess도 이 값을 상속한다.

```sh
DOCKER_HOST=unix:///Users/junje/.lima/shoppinglive-cdc/sock/docker.sock \
  docker info --format '{{.Name}} {{.ServerVersion}}'
DOCKER_HOST=unix:///Users/junje/.lima/shoppinglive-cdc/sock/docker.sock \
  python3 local/cdc/smoke.py --project kafka-cdc-smoke-lima-my-run \
  --report .local-current/cdc/lima-smoke.json
```

기존 Desktop smoke가 `15432/39092/18083`을 사용 중이면 그 독립 project만 중지하고 host listener 해제를 확인한 뒤 VM 스택을 시작한다. 공용 kind·다른 작업자 DB를 중단하지 않는다. B용 별도 PostgreSQL은 같은 VM의 독립 `b-postgres.compose.yml`을 사용하며 `127.0.0.1:25433`, DB/user `catalog_cdc_b`, 로컬 테스트 password `cdc_b_local`이다. 이 폐기 가능한 계정은 실제 DB에 사용하지 않는다. C용 별도 PostgreSQL은 `c-postgres.compose.yml`, `127.0.0.1:25434`, DB/user `core_refunds_c`, 로컬 테스트 password `core_refunds_c_local`이다. C의 기존 Desktop DB `25432`는 보존하며 데이터를 복사하지 않는다. D의 기존 Desktop `18384`도 유지한다. B/C/smoke의 project·DB·볼륨은 서로 다르다.

```sh
DOCKER_HOST=unix:///Users/junje/.lima/shoppinglive-cdc/sock/docker.sock \
  docker compose -f local/cdc/b-postgres.compose.yml up -d --wait
DOCKER_HOST=unix:///Users/junje/.lima/shoppinglive-cdc/sock/docker.sock \
  docker compose -f local/cdc/c-postgres.compose.yml up -d --wait
```

### Core DB와 connector 등록

1. **데이터 보존부터 확인한다.** [기본 Compose](../README.md#데이터-보존과-설정-적용)는 PostgreSQL 이름 있는 볼륨을 유지한다. 반면 [k8s dev 설정](../../k8s/overlays/dev/datatier/postgres.yaml)은 `Recreate`·`emptyDir`이므로 현재와 다른 args·env를 적용하면 Pod 교체로 DB·slot/WAL이 사라질 수 있다. 적용 전에 소유자와 백업·복원 계획을 확인한다. `wal_level` 변경에는 서버 재시작이 필요하며, 적용 후 `SHOW wal_level`과 slot/sender 제한을 확인한다. DB 목록을 늘리려고 기존 볼륨을 지우지 않는다.
2. 토픽을 준비하고 호환 Catalog 소비자와 스키마를 먼저 적용한다. Backend #379의 Core V109·Catalog V5를 포함한 각 서비스의 Flyway migration을 적용하고 Core `event_outbox`를 확인한다. 이어 **모든 Core 인스턴스**에서 일반·lease/claim relay가 Catalog 토픽을 제외하는지 확인한다. connector는 이 확인 전 등록하지 않는다. Infra의 CDC 준비 SQL이 Backend 업무 마이그레이션을 대신하지 않으며, 실제 앱 DB에는 `smoke-schema.sql`을 실행하지 않는다.
3. 기존 상품·SKU를 채울 때는 Core의 `commercecore.catalog.backfill.enabled=true`를 명시한 기동에서 초기 적재 완료를 확인하고, 이후 기동에서는 해당 설정을 끈다. backfill은 기존 Product/SKU와 삭제 이력을 같은 버전의 Outbox 스냅샷으로 기록한다. Debezium의 `snapshot.mode=initial`은 **이미 Outbox에 있는 행**을 읽는 것이므로 이 초기 적재를 대신하지 않는다. 상품·SKU 변경의 Outbox 기록과 기본 60초 재고 배치는 새 Core 코드에서 동작하므로 connector 등록 뒤 켜는 별도 생산 스위치가 있다고 가정하지 않는다. 전환 중 생성된 Outbox를 보존한다.
4. Backend migrations 이후 `prepare.sql`을 **해당 DB의 테이블 소유자**로 실행한다. `catalog_cdc`는 LOGIN/REPLICATION·DB 접속·public 사용·Outbox SELECT만 받는다. publication을 직접 생성하므로 connector에는 superuser/테이블 소유권이 필요 없다. 이 SQL은 CDC 권한·publication을 준비하며 업무 스키마를 만들지 않는다.
5. `docker compose -f local/docker-compose.yml --profile cdc up -d --build`로 이미지/worker를 시작한 뒤 `CDC_DATABASE_PASSWORD`를 로컬 비밀 환경으로 주입해 검증·등록한다. 최초 등록은 자동이 아니다. 기존 worker에 connector가 이미 등록돼 있다면 재시작 시 자동 재개될 수 있으므로, 재전환 전에 등록 상태와 중지 여부부터 확인한다. 예시의 compose exec에는 `-e CDC_DATABASE_PASSWORD`를 지정한다. connector REST config/compact config topic에는 자격증명이 보관되므로 접근을 제한하고 원문 config 응답을 보고서에 출력하지 않는다. k8s에는 Connect Deployment가 없으며, 별도 배포가 필요하다.

```sh
# CDC_DATABASE_PASSWORD는 별도 환경에서 주입한다(문서/파일에 실값을 쓰지 않는다).
docker compose -f local/docker-compose.yml exec -T -e CDC_DATABASE_PASSWORD postgres \
  psql -X -v ON_ERROR_STOP=1 -U shoppinglive -d commercecore < local/cdc/prepare.sql
python3 local/cdc/register.py --validate-only
python3 local/cdc/register.py
curl -fsS http://127.0.0.1:18083/connectors/core-catalog-outbox/status
```

등록 PUT은 같은 이름으로 재실행 가능하다. `CDC_DATABASE_HOST`, `CDC_DATABASE_NAME`, `CDC_SLOT_NAME`, `CDC_PUBLICATION_NAME`, `CONNECT_URL`로 별도 통합 DB를 지정할 수 있다. publication/slot 이름은 앱 DB와 함께 일관되게 유지하고, 여러 connector가 같은 slot을 동시에 사용하지 않는다. prepare.sql 기본 이름을 바꿀 경우 사본을 해당 독립 환경에만 적용한다. Core만 등록한다. Payment의 별도 DB Outbox는 이 connector 대상이 아니다.

## 감시·보관·장애 복구

`monitor.sql`을 Core DB에서 실행하고 Connect task 상태, Catalog consumer lag, 상품/SKU 버전·누락·중복 지표를 함께 본다. 주요 지표는 `active`, `restart_lsn`, `confirmed_flush_lsn`, `retained_wal_bytes`, `unconfirmed_bytes`, `wal_status`와 DB 디스크 여유다. 장기 장애에는 WAL이 계속 쌓일 수 있다. `max_slot_wal_keep_size` 제한을 둘 때 slot 무효화 후 재적재 절차도 준비한다. 로컬 smoke는 임의 제한으로 데이터를 잃지 않도록 이 값을 바꾸지 않는다.

10초 heartbeat는 변경이 적을 때 offset 반영을 돕지만 DB 전체 WAL 관리의 대체물이 아니다. 다른 DB만 쓰이는 저활동 Core DB의 slot이 진행하지 않으면, connector 버전·권한·publication에 맞는 heartbeat action을 별도 설계하고 실행 증거로 확인한다. 현재 구성은 heartbeat action을 위해 업무 테이블을 갱신하지 않는다.

CDC는 `published_at`을 갱신하지 않는다. NULL을 실패/미발행으로 계산하거나 relay 정리 조건에 포함하지 않는다. 반대로 age TTL만으로 미확인 Catalog 행을 삭제하면, snapshot 전 등록 지연·slot 손실·재적재 때 영구 누락될 수 있다. 이번 변경은 Catalog Outbox 자동 삭제를 추가하지 않는다. 정리 도입 전 durable Connect offset·slot 진행점·최대 복구 중단 시간·Catalog 재적재 원본/완료 fence를 정의한다. 단순 `created_at < now()-interval`이나 `confirmed_flush_lsn`과 행 시간의 추측 매핑은 안전한 삭제 증거가 아니다.

Connect 재시작은 동일 group/config/offset/status 토픽, slot, publication, topic.prefix로 수행한다. `slot.drop.on.stop=false`를 유지한다. 장애 중 기록된 Outbox는 복구 후 이어서 전달하며 offset commit 경계에서는 중복될 수 있으므로 Catalog가 eventId·snapshot version으로 멱등 적용해야 한다. slot을 잃었거나 broker의 offset 데이터를 잃으면 조용히 최신 LSN부터 시작하지 않는다. 소비자 fence와 재적재 계획을 먼저 세운 뒤 별도 slot/offset으로 initial snapshot을 수행한다. 기본 Compose Kafka는 기존처럼 ephemeral이므로 컨테이너 **재생성** 시 offset 소실 위험이 있다. 독립 CDC Compose만 Kafka 데이터를 volume에 보관한다.

이 이어읽기는 DB의 slot·필요 WAL과 broker의 내부 토픽·offset이 남아 있을 때의 복구다. dev PostgreSQL Pod 교체로 DB까지 잃으면 Kafka offset만으로 업무 데이터를 복원할 수 없다. DB 백업 복원 또는 원본 재구성, schema·권한·publication 준비, Core backfill과 Catalog 재적재 범위를 먼저 정한다. `initial` snapshot도 소실된 Outbox 행을 복구하지 않는다. KafkaTopic CR이나 bootstrap이 토픽 이름을 다시 만든다고 기존 메시지·offset이 복원되는 것도 아니다.

## 전환과 되돌리기

전환은 위 [등록 절차](#core-db와-connector-등록)에 따라 데이터 보존 확인 → 토픽·소비자/스키마 준비 → 모든 Core relay의 Catalog 제외 → 필요한 backfill 완료 → CDC 권한/publication 준비 → connector 등록 → 실제 후속 메시지와 공개 조회 대조 순으로 진행한다. relay 배제 이전에 CDC를 켜면 이중 발행된다. REST RUNNING만 보지 말고 key·본문·version·lag·중복·비대상 미발행을 확인한다. 기존 알림·Live 경로와 기존 토픽·offset은 보존한다. 이 문서 변경에서 배포나 런타임 재검증은 수행하지 않았다.

되돌리기: 먼저 connector를 pause/stop하고 task 정지·offset flush를 확인한다. Catalog 생산을 fence하고 마지막 전송 경계를 기록한다. 기존 소비자는 유지한다. 단순히 relay 제외 조건을 제거하면 이미 CDC 발행한 행도 NULL `published_at` 때문에 재발행된다. 소비자 멱등성·중복 대조/명시적인 재생 범위를 준비한 뒤에만 relay로 담당을 전환한다. 자동 fallback이나 outbox 일괄 완료 표시는 하지 않는다. slot/publication/내부 토픽은 장애 중 삭제하지 않는다. CDC를 완전히 폐기할 때는 재처리/재적재 필요가 없다는 확인과 WAL 영향 검토 후 별도 승인된 유지보수로 제거한다.

선택 이미지 3.3.2.Final의 [BaseSourceTask.stop](https://github.com/debezium/debezium/blob/v3.3.2.Final/debezium-core/src/main/java/io/debezium/connector/common/BaseSourceTask.java)은 offset commit 오류에도 finally에서 source 정리를 수행한다. 로컬 3.2.4 시험에서는 broker 재시작 때 offset reader 종료 예외로 기존 task가 slot을 점유하고 JMX 중복 등록을 남겼으므로 채택하지 않았다. worker task 종료 grace는 60초, container 종료 grace는 90초로 명시한다. REST RUNNING만으로 복구를 판정하지 않고 실제 후속 eventId 전달·slot 활성 연결을 대조한다.
