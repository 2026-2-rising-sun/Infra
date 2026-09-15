# terraform/modules/ivs

라이브 방송용 AWS IVS(Interactive Video Service) 채널을 정의할 모듈. `live-service` 가 사용한다.

**상태: 향후 정의.** 팀이 AWS 사용 범위를 합의한 뒤 채운다.

채울 때 최소한 다음을 결정해야 한다.

- 채널을 방송마다 동적으로 만들지, 미리 풀로 만들어 두고 재사용할지
- 채널 타입(STANDARD/BASIC)과 레코딩 설정(S3 저장 여부)
- 스트림 키 발급/회수 경로와 권한 경계
