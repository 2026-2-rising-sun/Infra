// 시나리오 1: 방송 시작 폭주.
//
// 알림 신청자 N 명(seed.mjs 가 만듦)이 있는 방송을 판매자가 시작한다 → live 가 Kafka 로 이벤트 발행 →
// notification 이 N 명에게 발송 → 0~30초 안에 N 명이 시청 페이지에 들어온다.
// 시청자 한 명은 Frontend 와 같이 15초마다 heartbeat 를 보내고, 가끔 채팅을 쓰고, 시청자 수를 읽는다.
//
// 보는 것: notification 컨슈머 랙이 0 으로 돌아오는 시간, live 파드 수와 SSE 연결 수, p99 지연.
// SSE 연결 자체는 두 가지 방법 중 하나로 연다.
//   - 기본 k6: 이 스크립트 옆에서 `node sse-holder.mjs --count N` 을 돌려 연결을 열어 둔다.
//   - xk6-sse 로 빌드한 k6: `01-broadcast-start-surge-sse.js` 를 쓴다(이 파일은 plain k6 에서 import 가 실패한다).
import { check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';
import { USERS, RAMP, HOLD, HEARTBEAT_INTERVAL, CHAT_EVERY, api, thresholds } from './lib/config.js';
import { seed, userFor } from './lib/seed.js';
import { login, fresh, bearer } from './lib/auth.js';
import { postJson, getJson, unwrap } from './lib/http.js';

const heartbeat = new Trend('heartbeat_duration', true);
const chat = new Trend('chat_duration', true);
const viewerCount503 = new Counter('viewer_count_503');

export const options = {
  scenarios: {
    viewers: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: RAMP, target: USERS }, // 알림을 받고 30초 안에 들어온다
        { duration: HOLD, target: USERS }, // 방송을 보는 동안 머문다
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    ...thresholds,
    heartbeat_duration: ['p(95)<500'],
    viewer_count_503: ['count==0'],
  },
  tags: { scenario: 'broadcast-start-surge' },
};

// 판매자가 방송을 시작한다. 이 순간이 notification 랙이 치솟는 시점이다(Grafana 에서 시작 시각을 적어 둔다).
export function setup() {
  const seller = login(seed.sellerEmail, seed.sellerPassword);
  const res = postJson(api('live', `/v1/seller/broadcasts/${seed.broadcastId}/start`), {}, bearer(seller), { tags: { name: 'broadcast-start' } });
  const ok = check(res, { 'broadcast start 200/409': (r) => r.status === 200 || r.status === 409 });
  if (!ok) throw new Error(`broadcast start failed: ${res.status} ${res.body}`);
  console.log(`방송 시작: 방송 ID=${seed.broadcastId} 시각=${new Date().toISOString()} 상태 코드=${res.status}`);
  return { startedAt: Date.now() };
}

// VU 마다 모듈 인스턴스가 따로 있어서 아래 변수는 VU 하나의 상태다. 한 번만 로그인하고 토큰을 재사용한다.
let session = null;
let viewerId = null;
let beats = 0;

export default function () {
  if (!session) {
    const u = userFor(__VU);
    session = login(u.email, u.password);
    viewerId = uuid();
  }
  session = fresh(session);
  const id = seed.broadcastId;

  const hb = postJson(api('live', `/v1/broadcasts/${id}/viewers/heartbeat`), { viewerId }, {}, { tags: { name: 'heartbeat' } });
  heartbeat.add(hb.timings.duration);
  check(hb, { 'heartbeat 200': (r) => r.status === 200 });

  if (++beats % CHAT_EVERY === 0) {
    const c = postJson(api('live', `/v1/broadcasts/${id}/chats`), { content: `k6 ${__VU}-${beats}` }, bearer(session), { tags: { name: 'chat' } });
    chat.add(c.timings.duration);
    check(c, { 'chat 2xx': (r) => r.status >= 200 && r.status < 300 });
  }

  const total = getJson(api('live', `/v1/broadcasts/${id}/viewers`), {}, { tags: { name: 'viewer-count' } });
  if (total.status === 503) viewerCount503.add(1); // Redis 가 없으면 시청자 수 API 가 503 을 낸다
  else check(total, { 'viewer count 200': (r) => r.status === 200 && unwrap(r) !== null });

  sleep(HEARTBEAT_INTERVAL);
}

export function teardown() {
  // 방송은 끝내지 않는다. 같은 방송으로 3·4번 시나리오를 다시 돌리기 때문이다.
}

function uuid() {
  const h = () => Math.floor((1 + Math.random()) * 0x10000).toString(16).slice(1);
  return `${h()}${h()}-${h()}-4${h().slice(1)}-a${h().slice(1)}-${h()}${h()}${h()}`;
}
