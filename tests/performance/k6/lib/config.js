// 모든 시나리오가 공유하는 설정. 값은 환경변수로 덮어쓴다 (k6 run -e KEY=value).
//
// BASE_URL 은 Gateway(Envoy) 입구다. 서비스별 접두사 /api/<service> 를 붙여 호출하면
// Gateway 가 접두사를 떼고 각 서비스로 보낸다. Frontend 의 vite 프록시와 같은 계약이다.
export const BASE_URL = (__ENV.BASE_URL || 'http://localhost:9080').replace(/\/$/, '');

// 시드 스크립트(seed.mjs)가 만든 방송·쿠폰·사용자 목록.
// k6 의 open() 은 그 호출이 있는 파일(lib/seed.js) 기준으로 상대 경로를 푼다. 바꿀 땐 절대 경로를 준다.
export const SEED_FILE = __ENV.SEED_FILE || '../.seed/seed.json';

// 동시 사용자 수와 유지 시간. 기준선은 작게 잡고 깨지는 지점을 찾을 때 올린다.
export const USERS = Number(__ENV.USERS || 50);
export const RAMP = __ENV.RAMP || '30s'; // 설계안: 방송 시작 후 30초 안에 N 명 유입
export const HOLD = __ENV.HOLD || '3m';
export const HEARTBEAT_INTERVAL = Number(__ENV.HEARTBEAT_INTERVAL || 15); // live 의 시청자 창 60초, Frontend 는 15초마다 보낸다
export const CHAT_EVERY = Number(__ENV.CHAT_EVERY || 4); // heartbeat 몇 번마다 채팅 1건

export const api = (service, path) => `${BASE_URL}/api/${service}${path}`;

// 설계안 4.7 의 알림 규칙과 같은 기준이다. 임계값을 넘으면 k6 가 0 이 아닌 코드로 끝난다.
export const thresholds = {
  http_req_failed: ['rate<0.05'],
  http_req_duration: ['p(99)<1000'],
};

export const jsonHeaders = { 'Content-Type': 'application/json', Accept: 'application/json' };
