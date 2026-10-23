# 팀원 최초 설치·실행

**최초에는 `make setup`, 이후에는 `make start`만 실행합니다.** 백엔드 5개와 인프라는 kind에서, 프론트는 호스트의 Vite에서 실행됩니다. 실제 결제·영상 송출은 연결하지 않는 로컬 체험 환경입니다.

## 1. 최초 준비

Docker Desktop을 설치·실행하고 GitHub 조직의 Infra·Backend·Frontend 저장소 읽기 권한을 준비합니다. Git HTTPS 인증은 먼저 설정합니다. 이 스크립트는 로그인 정보나 개인 토큰을 받지 않습니다.

필요 도구: Git, Make, Python 3.10 이상, Node.js 24 이상, Java 21, kind, kubectl. macOS에서 Homebrew가 설치되어 있다면:

```bash
brew install git python node@24 openjdk@21 kind kubernetes-cli
export PATH="$(brew --prefix node@24)/bin:$PATH"
```

Make가 없다면 macOS 명령행 개발 도구를 설치합니다(`xcode-select --install`). Java 21은 macOS Homebrew 기본 위치에서 자동 탐색합니다. 다른 설치 방식·운영체제에서는 `JAVA_HOME`을 Java 21 경로로 지정하세요. Windows는 WSL2와 Docker 연동 환경이 필요하며, Windows/Linux의 최초 설치는 아직 직접 검증하지 않았습니다.

Docker에는 단일 클러스터 기준 메모리 8GB 이상을 할당합니다. 이 검증은 Apple Silicon / Docker 8GB에서 기존 kind를 중지하고 진행했습니다. 다른 클러스터도 실행한다면 메모리를 추가 확보해야 합니다. 최초 이미지 다운로드·빌드에는 네트워크와 충분한 디스크 공간이 필요합니다.

## 2. 코드를 받고 설치하기

Infra의 `main` 브랜치를 받습니다. 기존 Infra 작업 폴더가 있으면 새 폴더에서 실행하세요.

```bash
git clone --branch main https://github.com/2026-2-rising-sun/Infra.git ShoppingLive-Infra
cd ShoppingLive-Infra
make setup
```

자동으로 처리하는 내용:

- `.local-team/Backend`, `.local-team/Frontend`에 [versions.json](versions.json)의 고정 커밋을 받습니다. 다른 폴더의 미커밋 파일에 의존하지 않습니다.
- 전용 kind `shoppinglive-team`을 생성하고 PostgreSQL·Kafka·Redis 및 백엔드 5개를 설치합니다.
- Grafana·Prometheus·Loki·Tempo·Alloy·exporter·Kafka UI·RedisInsight를 설치하고 백엔드의 관측 설정을 연결합니다.
- 프론트 의존성을 설치하고 체험용 상품 1개·진행 중인 stub 방송 1개를 준비합니다.

설치가 중간에 실패하면 오류 원인을 해결한 뒤 `make setup`을 다시 실행합니다. 완료된 단계와 생성된 샘플 ID를 기록하여 반복 생성하지 않습니다. 이미 완료된 환경에 재실행해도 구매·방송 상태를 초기화하지 않습니다.

## 3. 평소 실행

Docker Desktop을 켠 뒤 **같은 Infra 폴더**에서:

```bash
make start
```

정지된 전용 kind 노드를 다시 켜고, 백엔드 준비를 기다린 뒤 프론트·API 연결·관리 UI를 함께 실행합니다. 이 터미널은 열어 둡니다. 서비스별 `bootRun`이나 별도 Frontend 명령은 필요 없습니다.

| 화면 | 기본 주소 | 확인할 것 |
|---|---|---|
| 프론트 | http://127.0.0.1:5174 | 로그인 → 상품 구매 → Mock 결제 → 환불, 방송 입장 |
| Grafana | http://127.0.0.1:13000 | 대시보드의 요청 수·오류·응답시간, Explore의 Loki 로그·Tempo 트레이스 |
| Kafka UI | http://127.0.0.1:18080 | Topics → `commerce.payment-group.v1`(결제·환불), `commerce.sales-info.v1`(판매정보), `live.broadcast.v1`(방송) → Messages |
| RedisInsight | http://127.0.0.1:15540 | 자동 등록된 로컬 Redis → Browser → 키·값·TTL |

상품·방송의 정확한 링크는 실행 결과에 출력됩니다. 기본 테스트 계정은 `user / user`, 판매자는 `seller / seller`입니다. 상품 구매는 주문서 작성 → 통합 결제하기 순서입니다. Mock 결제로 실제 비용이 발생하지 않습니다. 방송 입장·상태·시청자 수는 확인할 수 있지만 stub 영상은 재생되지 않습니다.

Grafana 대시보드는 로그인 없이 조회합니다. **로그·트레이스를 자유롭게 탐색하려면** 아래 명령으로 자기 환경의 관리자 계정을 확인하고 Grafana 우측 `Sign in`으로 로그인한 뒤 `Explore`에서 Loki 또는 Tempo를 선택합니다. 비밀번호는 환경마다 달라 팀 문서에는 기록하지 않습니다.

```bash
make grafana-login
```

RedisInsight는 최초 이용 시 사용자가 이용약관을 확인·동의해야 합니다. 이후 사전 설정한 Redis 연결을 확인합니다. 스크립트가 약관에 자동 동의하지 않습니다. Kafka UI와 RedisInsight는 로컬 루프백 주소로만 연결합니다. `localhost`는 팀원 각자의 컴퓨터를 뜻합니다.

```bash
make status  # 앱·인프라·모니터링 Pod 상태 확인
make ui      # 프론트 없이 관리 UI 3개만 연결
```

Slack 알림을 받으려면 webhook을 환경변수로 넘겨 관측 스택을 다시 적용합니다(값은 Git에 넣지 않습니다). 자세한 내용은 [1단계 통합 문서의 Slack 알림](../../docs/observability-phase1.md#slack-알림)을 참고하세요.

```bash
KUBECONFIG=.local-team/kubeconfig SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...' \
  python3 observability/local/deploy.py --context kind-shoppinglive-team --app-namespace shoppinglive-team --apply
```

Ctrl+C는 해당 명령이 만든 프론트·포트 연결만 종료합니다. kind와 서비스는 계속 실행됩니다. 컴퓨터 자원을 반환하려면 연결을 종료한 뒤 아래처럼 노드만 중지할 수 있습니다. 다음 `make start`가 다시 켭니다.

```bash
docker stop shoppinglive-team-control-plane
```

## 필요한 경우만 확인

- **포트 충돌:** 기존 연결을 종료하거나 `PORT_OFFSET=1000 make start`를 사용합니다. 프론트 6174, Grafana 14000, Kafka UI 19080, RedisInsight 16540, API 19481~19485로 함께 이동합니다. 기존 프로세스를 강제로 종료하지 않습니다.
- **설치/실행 실패:** 터미널 오류와 `.local-team/logs/`를 확인합니다. Kubernetes 오류는 `KUBECONFIG=.local-team/kubeconfig kubectl -n shoppinglive-team get pods`로 확인합니다. 관측 스택은 네임스페이스 `shoppinglive-observability`입니다.
- **저장 위치:** 소스·상태·개발용 키·백업은 Git에서 제외된 `.local-team/`에 있습니다. 이 폴더를 커밋하거나 공유하지 않습니다. 사용자 기본 kubeconfig/current-context는 변경하지 않습니다.
- **데이터 수명:** PostgreSQL·Kafka·Redis는 기존 개발 스크립트의 `emptyDir`를 사용합니다. 일반 연결 종료·노드 정지는 삭제 동작이 아니지만 Pod 재생성·클러스터 삭제 시 데이터가 사라질 수 있습니다. 영구 보관 환경이 아니므로 초기화 목적으로 Pod·클러스터를 삭제하지 마세요.
- **소스 변경:** 체험 환경의 소스는 검증한 커밋으로 고정합니다. 개발은 별도 Backend/Frontend 작업 폴더에서 진행합니다. `make setup`은 최신 브랜치를 자동으로 가져오거나 소스 변경을 덮어쓰는 업데이트 명령이 아닙니다.
- **기존 관측 환경:** `.local-team/state.json`이 없는 기존 Infra 작업 폴더의 `make ui`는 이전 `kind-shoppinglive-dev` 환경을 연결합니다. 새 팀 환경과 혼합하지 않습니다.

전체 관측 구성·지표·시나리오는 [1단계 통합 문서](../../docs/observability-phase1.md)를 참고하세요. API·이벤트 계약 변경, 실배포, 부하테스트는 이번 실행 도구의 범위에 포함되지 않습니다.
