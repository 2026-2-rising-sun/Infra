// 시나리오 3: Redis 장애.
//
// 시나리오 1 과 같은 부하를 주는 동안 Redis 파드를 지운다(사람이 다른 터미널에서):
//   kubectl -n shoppinglive-dev delete pod -l app.kubernetes.io/name=redis
//
// 설계안 4.5: Redis 가 죽으면 ① 채팅·좋아요의 파드 간 중계가 멈추고 ② 시청자 수 API 가 503 을 낸다.
// 여기서는 ②를 1초 간격 탐침으로 재서 "503 이 몇 초 지속됐는지"를 숫자로 남긴다.
// ①(SSE 끊김·복구)은 sse-holder.mjs 의 연결 수 로그로 본다.
import { check } from 'k6';
import { Counter, Gauge, Trend } from 'k6/metrics';
import { api } from './lib/config.js';
import { seed } from './lib/seed.js';
import { getJson } from './lib/http.js';
import { options as surge, setup as start, default as viewer } from './01-broadcast-start-surge.js';

const probe503 = new Counter('probe_503');
const outageSeconds = new Trend('viewer_count_outage_seconds');
const outageNow = new Gauge('viewer_count_outage_active');

export const options = {
  scenarios: {
    ...surge.scenarios,
    probe: { executor: 'constant-vus', vus: 1, duration: totalDuration(surge.scenarios.viewers.stages), exec: 'probe' },
  },
  thresholds: {
    http_req_failed: ['rate<0.20'], // 장애 실험이라 실패율 기준을 느슨하게 둔다
    http_req_duration: ['p(99)<2000'],
    viewer_count_outage_seconds: ['max<60'], // 설계안 1단계 허용치: 파드 재시작 공백 수십 초
  },
  tags: { scenario: 'redis-failure' },
};

export const setup = start;
export default viewer;

let outageStart = null;

export function probe() {
  const res = getJson(api('live', `/v1/broadcasts/${seed.broadcastId}/viewers`), {}, { tags: { name: 'probe' } });
  const down = res.status === 503 || res.status === 0;
  if (down) {
    probe503.add(1);
    outageNow.add(1); // k6 Gauge 는 add 가 "현재 값 설정"이다
    if (outageStart === null) { outageStart = Date.now(); console.warn(`viewer count DOWN at ${new Date().toISOString()} (status ${res.status})`); }
  } else {
    outageNow.add(0);
    if (outageStart !== null) {
      const sec = (Date.now() - outageStart) / 1000;
      outageSeconds.add(sec);
      console.warn(`viewer count UP after ${sec.toFixed(1)}s at ${new Date().toISOString()}`);
      outageStart = null;
    }
    check(res, { 'probe 200': (r) => r.status === 200 });
  }
  const until = Date.now() + 1000;
  while (Date.now() < until) { /* 1초 간격 */ }
}

function totalDuration(stages) {
  let sec = 0;
  for (const s of stages) {
    const m = /^(\d+)(s|m|h)$/.exec(s.duration);
    sec += Number(m[1]) * { s: 1, m: 60, h: 3600 }[m[2]];
  }
  return `${sec + 15}s`;
}
