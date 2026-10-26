// 시나리오 1 의 SSE 포함판. xk6-sse(https://github.com/phymbert/xk6-sse) 로 빌드한 k6 에서만 돈다.
//
//   xk6 build --with github.com/phymbert/xk6-sse   # 또는 README 의 docker 빌드
//   ./k6 run tests/performance/k6/01-broadcast-start-surge-sse.js
//
// 시청자 한 명이 SSE 를 연 채로 heartbeat·채팅을 보낸다. 연결 수는 live 가 노출하는
// shoppinglive_live_sse_connections 지표로 확인한다. plain k6 에서는 아래 import 가 실패하므로
// 그때는 01 + sse-holder.mjs 조합을 쓴다.
import sse from 'k6/x/sse';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import { USERS, RAMP, HOLD, HEARTBEAT_INTERVAL, CHAT_EVERY, api, thresholds } from './lib/config.js';
import { seed, userFor } from './lib/seed.js';
import { login, bearer } from './lib/auth.js';
import { postJson } from './lib/http.js';
import { setup as start } from './01-broadcast-start-surge.js';

const events = new Counter('sse_events');
const openTime = new Trend('sse_open_duration', true);

export const options = {
  scenarios: {
    viewers: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: RAMP, target: USERS },
        { duration: HOLD, target: USERS },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '20s',
    },
  },
  thresholds: { ...thresholds, sse_open_duration: ['p(95)<1000'] },
  tags: { scenario: 'broadcast-start-surge-sse' },
};

export const setup = start;

export default function () {
  const u = userFor(__VU);
  const session = login(u.email, u.password);
  const id = seed.broadcastId;
  const viewerId = `${__VU}-${Date.now()}`;
  const holdMs = toMs(HOLD);
  const t0 = Date.now();

  // sse.open 은 연결이 닫힐 때까지 블록한다. 그 안에서 타이머로 heartbeat 와 채팅을 보낸다.
  const res = sse.open(api('live', `/v1/broadcasts/${id}/events`), { headers: { Accept: 'text/event-stream' }, tags: { name: 'sse' } }, (client) => {
    let beats = 0;
    client.on('open', () => openTime.add(Date.now() - t0));
    client.on('event', () => events.add(1));
    client.on('error', (e) => console.warn(`SSE 오류: 가상 사용자=${__VU} 원인=${e.error()}`));
    const timer = setInterval(() => {
      postJson(api('live', `/v1/broadcasts/${id}/viewers/heartbeat`), { viewerId }, {}, { tags: { name: 'heartbeat' } });
      if (++beats % CHAT_EVERY === 0) postJson(api('live', `/v1/broadcasts/${id}/chats`), { content: `k6 ${__VU}-${beats}` }, bearer(session), { tags: { name: 'chat' } });
      if (Date.now() - t0 > holdMs) { clearInterval(timer); client.close(); }
    }, HEARTBEAT_INTERVAL * 1000);
  });
  check(res, { 'sse 200': (r) => r && r.status === 200 });
  sleep(1);
}

function toMs(d) {
  const m = /^(\d+)(ms|s|m|h)$/.exec(d);
  if (!m) return 180000;
  return Number(m[1]) * { ms: 1, s: 1000, m: 60000, h: 3600000 }[m[2]];
}
