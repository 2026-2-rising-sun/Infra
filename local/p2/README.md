# P2 전용 로컬 DB

이 Compose는 새 프로젝트 `shoppinglive-p2-local`과 자체 `postgres-data` 볼륨을 사용한다.
기존 `local/docker-compose.yml`, `shoppinglive-local` 프로젝트, 5432 PostgreSQL 및 그 데이터는 변경하지 않는다.
기본 포트는 loopback `127.0.0.1:15432`이며 기존 포트가 사용 중이면 `.env`의 `P2_POSTGRES_PORT`를 바꾼다.
이미 실행 중인 프로세스의 포트를 가져오거나 기존 DB를 삭제하는 명령은 없다.

Infra 저장소에서 실행한다.

```sh
sh local/p2/prepare-env.sh
docker compose --env-file local/p2/.env -f local/p2/compose.yaml config --quiet
docker compose --env-file local/p2/.env -f local/p2/compose.yaml up -d --wait
docker compose --env-file local/p2/.env -f local/p2/compose.yaml exec -T postgres psql -U p2_local -d postgres -c '\l'
```

`prepare-env.sh`는 0600 `.env`에 새 난수 비밀번호를 만들며 기존 파일을 덮어쓰지 않는다.
설정을 잃어버리면 기존 DB 비밀번호가 자동 변경되는 것이 아니다. 실행 환경과 볼륨에 맞는 원래 파일을 보존한다.
초기화 SQL은 이 프로젝트의 빈 볼륨에서만 member/shopping/commerce/live DB 4개를 만든다.
각 서비스의 Flyway가 해당 DB의 스키마를 생성한다. 기존 비회원 DB 정리나 Commerce V3 삭제 절차가 시작 조건이 아니다.
이 개발 사용자에게는 로컬 DB 생성 권한이 있으며 운영 자격증명으로 재사용하지 않는다.

## 실제 서비스 실행

Backend의 `scripts/local/auth-env.cjs`로 private PEM·public JWKS·방향별 서비스 토큰을 생성한다.
access/refresh TTL은 필수 입력이며 아래 값은 로컬 실험 예시다. 운영 기본값을 정하지 않는다.

```sh
# Infra 저장소에서 생성한 .env는 hex 비밀번호와 숫자 포트만 포함한다.
set -a
. ./local/p2/.env
set +a
export POSTGRES_PORT="$P2_POSTGRES_PORT" POSTGRES_USER=p2_local POSTGRES_PASSWORD="$P2_POSTGRES_PASSWORD"

cd /absolute/path/to/Backend
npm ci --prefix scripts/contracts --ignore-scripts
node scripts/local/auth-env.cjs create --access-ttl PT15M --refresh-ttl P30D
```

출력된 env.json 절대 경로를 `P2_AUTH_ENV`로 지정한다. JDK 21의 경로를 `JAVA21_HOME`으로 지정하고 JAR을 만든다.
실제 실행은 네 서비스 모두 `local` 프로필이며 JWT 필터를 우회하지 않는다.

```sh
P2_AUTH_ENV=/absolute/path/to/generated/env.json
JAVA_HOME="$JAVA21_HOME" ./gradlew :services:member-service:bootJar :services:shopping-service:bootJar :services:commerce-service:bootJar :services:live-service:bootJar
node scripts/local/auth-env.cjs exec member --env "$P2_AUTH_ENV" -- "$JAVA21_HOME/bin/java" -jar services/member-service/build/libs/member-service-0.0.1-SNAPSHOT.jar --spring.profiles.active=local
```

각 서비스는 별도 터미널에서 같은 DB 환경과 같은 `P2_AUTH_ENV`로 실행한다.
위 명령의 `member`와 `member-service`를 shopping/commerce/live로 바꾸면 된다.
기본 애플리케이션 포트는 8081/8082/8083/8084이고 DB는 15432의 각 서비스명 DB를 사용한다.
`GET /actuator/health/readiness` 200 이후 실제 Member 가입→로그인으로 얻은 JWT를 사용한다.
토큰·비밀번호를 계약 예시나 Git에 저장하지 않는다. JSON 키 파일을 컨테이너에서 사용한다면 내부에서도 동일 키 파일을 읽을 수 있게 경로와 mount를 지정한다.

ADMIN은 Member JAR의 `--bootstrap-admin` CLI로 신규 계정만 생성한다.
대상 URL은 `jdbc:postgresql://127.0.0.1:<P2_POSTGRES_PORT>/member`, schema는 `public`, 사용자 `p2_local`이다.
다음 환경변수를 명시한 뒤 실행하며 서버가 자동 승격하는 HTTP 경로는 없다.

- `MEMBER_BOOTSTRAP_DB_URL`, `MEMBER_BOOTSTRAP_DB_SCHEMA`, `MEMBER_BOOTSTRAP_DB_USER`, `MEMBER_BOOTSTRAP_DB_PASSWORD`
- `MEMBER_BOOTSTRAP_ADMIN_EMAIL`, `MEMBER_BOOTSTRAP_ADMIN_PASSWORD`, `MEMBER_BOOTSTRAP_ADMIN_DISPLAY_NAME`

```sh
"$JAVA21_HOME/bin/java" -jar services/member-service/build/libs/member-service-0.0.1-SNAPSHOT.jar --bootstrap-admin
```

## 필요한 상대 서비스만 Mock으로 대체

| 모드 | 실제 프로세스 | Mock |
|---|---|---|
| 단독 도메인 | 대상 서비스+새 DB | 필요한 Shopping/Commerce/Live 의존 |
| 실제 인증 | Member+대상 서비스+새 DB | 아직 띄우지 않은 내부 의존 |
| 전체 통합 | 네 서비스+새 DB | 기존 결제 gateway·AWS IVS 외부 Mock만 유지 |

예를 들어 실제 Member·Shopping을 띄우고 Commerce만 대체한다면 Backend에서 다음 명령을 실행한다.

```sh
node scripts/local/contracts.cjs mock commerce 8083
```

실제 Commerce와 Prism은 같은 포트를 동시에 사용하지 않는다. Mock을 종료한 후 실제 Commerce를 켠다.
의존 주소를 명시할 때 Shopping은 `--shopping.sales-client.base-url=http://localhost:8083`,
Commerce는 `--commerce.shopping-client.base-url=http://localhost:8082`, Live는
`--live.products.mode=http --live.products.shopping-url=http://localhost:8082 --live.products.commerce-url=http://localhost:8083`를 쓴다.
caller 토큰은 Backend의 env 준비기가 서비스별로 전달한다. Prism의 토큰 형태 통과는 실제 인증 검증이 아니다.
Prism은 고정 응답이므로 ID/가격을 fixture와 맞추고 실제 재고·멱등성·소유권 검증으로 기록하지 않는다.
실제 JWT 로그인과 ADMIN CLI, 계약 검증 세부 명령은 Backend의 `contracts/docs/local-execution.md`를 따른다.

## 종료와 보존

```sh
docker compose --env-file local/p2/.env -f local/p2/compose.yaml down
```

이 명령은 P2 프로젝트의 컨테이너·네트워크만 종료하고 새 DB 볼륨은 보존한다.
기존 로컬 스택을 내리거나 `down -v`로 데이터를 삭제하지 않는다. 다시 `up -d --wait`하면 같은 DB를 사용한다.
