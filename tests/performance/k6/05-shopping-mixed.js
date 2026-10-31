// 시나리오 5: Shopping 상품 조회 혼합 부하 (Infra #49).
//
// 방송 1개 시청자 3,000명일 때 Shopping 이 받는 요청을 API 별 비율 그대로 보낸다. 합계 416 RPS.
//   MODE=fixed (기본)  : 416 RPS × SCALE 을 DURATION(5m) 동안
//   MODE=step          : 같은 비율로 STEPS 배수만큼 단계별로 올린다. 단계마다 STEP_DURATION(1m)
// 판정: p99 ≤ 300ms, 오류율 < 1%, dropped iterations 0. 단계 부하는 처음 기준을 넘은 단계와 원인을 출력한다.
//
// 공개 API 는 Gateway(BASE_URL/api/shopping), 내부 API 는 Gateway 밖이라 Shopping Service(SHOPPING_URL)에
// 직접 붙고 X-Service-Token(SERVICE_TOKEN)을 보낸다. 상품은 seed.mjs --products 가 만든 .seed/products.json.
import { check } from 'k6';
import http from 'k6/http';
import { SharedArray } from 'k6/data';
import { BASE_URL } from './lib/config.js';

// 요청/초. 근거는 Infra #49 표.
const APIS = {
  detail: 99, // GET /v1/products/{id}
  coupons: 90, // GET /v1/products/{id}/coupons
  purchase_check: 9, // GET /v1/products/{id}/purchase-check
  internal_bulk: 200, // GET /v1/internal/products?ids= (Live, 10개)
  internal_single: 18, // GET /v1/internal/products/{id} (Commerce)
};
const TOTAL = Object.values(APIS).reduce((a, b) => a + b, 0); // 416

const MODE = __ENV.MODE || 'fixed';
const SCALE = Number(__ENV.SCALE || 1);
const STEPS = MODE === 'step' ? (__ENV.STEPS || '0.5,1,1.5,2,3,4').split(',').map(Number) : [SCALE];
const STEP_SECONDS = MODE === 'step' ? seconds(__ENV.STEP_DURATION || '1m') : seconds(__ENV.DURATION || '5m');
const FOCUS = __ENV.FOCUS === '1';
const SHOPPING_URL = (__ENV.SHOPPING_URL || 'http://localhost:8081').replace(/\/$/, '');
const P99_MS = 300;

const products = new SharedArray('products', () => JSON.parse(open(__ENV.PRODUCTS_FILE || './.seed/products.json')).productIds);

function seconds(d) {
  const m = /^(\d+)(s|m)$/.exec(d);
  if (!m) throw new Error(`기간은 30s, 5m 형식이어야 합니다: ${d}`);
  return Number(m[1]) * (m[2] === 'm' ? 60 : 1);
}

const scenarios = {};
const thresholds = {};
STEPS.forEach((scale, i) => {
  const step = String(i + 1);
  for (const [api, rps] of Object.entries(APIS)) {
    const rate = rps * scale;
    scenarios[`s${step}_${api}`] = {
      executor: 'constant-arrival-rate',
      exec: api,
      rate: Math.round(rate * 10), // 0.1 RPS 단위까지 맞춘다
      timeUnit: '10s',
      duration: `${STEP_SECONDS}s`,
      startTime: `${i * STEP_SECONDS}s`,
      preAllocatedVUs: Math.ceil(rate / 2) + 2,
      maxVUs: Math.ceil(rate) + 10, // 응답 1초까지 버틴다. 넘으면 dropped 로 드러난다
      tags: { step, api },
    };
    // dropped_iterations 에는 scenario 태그만 붙는다.
    thresholds[`dropped_iterations{scenario:s${step}_${api}}`] = ['count==0'];
  }
  thresholds[`http_req_duration{step:${step}}`] = [`p(99)<=${P99_MS}`];
  thresholds[`http_req_failed{step:${step}}`] = ['rate<0.01'];
  thresholds[`http_reqs{step:${step}}`] = ['count>=0']; // 요약에 단계별 요청 수를 남기려는 항목
});
for (const api of Object.keys(APIS)) {
  thresholds[`http_req_duration{api:${api}}`] = [`p(99)<=${P99_MS}`];
  thresholds[`http_reqs{api:${api}}`] = ['count>=0'];
}

export const options = { scenarios, thresholds, summaryTrendStats: ['avg', 'p(95)', 'p(99)', 'max'] };

export function setup() {
  if (!__ENV.SERVICE_TOKEN) throw new Error('SERVICE_TOKEN 이 필요합니다. README 의 Secret 읽는 방법을 참고한다.');
  if (products.length < 10) throw new Error('상품이 10개 이상 필요합니다. seed.mjs --products 를 먼저 실행한다.');
}

const pick = () => (FOCUS ? products[0] : products[Math.floor(Math.random() * products.length)]);
// 방송 하나의 상품 10개. 집중 모드는 모두 같은 방송(앞 10개), 아니면 무작위 10개.
function bulkIds() {
  if (FOCUS) return products.slice(0, 10);
  const start = Math.floor(Math.random() * (products.length - 9));
  return products.slice(start, start + 10);
}

const pub = (path, name) => http.get(`${BASE_URL}/api/shopping${path}`, { tags: { name } });
const internal = (path, name) => http.get(`${SHOPPING_URL}${path}`, { headers: { 'X-Service-Token': __ENV.SERVICE_TOKEN }, tags: { name } });
const ok = (res) => check(res, { 'status 200': (r) => r.status === 200 });

export const detail = () => ok(pub(`/v1/products/${pick()}`, 'detail'));
export const coupons = () => ok(pub(`/v1/products/${pick()}/coupons`, 'coupons'));
export const purchase_check = () => ok(pub(`/v1/products/${pick()}/purchase-check?quantity=1`, 'purchase_check'));
export const internal_bulk = () => ok(internal(`/v1/internal/products?ids=${bulkIds().join(',')}`, 'internal_bulk'));
export const internal_single = () => ok(internal(`/v1/internal/products/${pick()}`, 'internal_single'));

export function handleSummary(data) {
  const m = data.metrics;
  const val = (k, f) => (m[k] ? m[k].values[f] : 0);
  const ms = (v) => `${Math.round(v)}ms`;
  const totalSeconds = STEPS.length * STEP_SECONDS;
  const lines = [`shopping-mixed mode=${MODE} focus=${FOCUS} products=${products.length} steps=${STEPS.join(',')} × ${STEP_SECONDS}s`, ''];

  lines.push('API별 (전 구간)  목표RPS  실제RPS  차이   p99');
  for (const [api, rps] of Object.entries(APIS)) {
    const target = rps * STEPS.reduce((a, s) => a + s, 0) / STEPS.length;
    const actual = val(`http_reqs{api:${api}}`, 'count') / totalSeconds;
    lines.push(`  ${api.padEnd(16)} ${target.toFixed(1).padStart(7)} ${actual.toFixed(1).padStart(8)} ${(((actual - target) / target) * 100).toFixed(1).padStart(5)}%  ${ms(val(`http_req_duration{api:${api}}`, 'p(99)'))}`);
  }

  lines.push('', '단계  목표RPS  실제RPS   p99    오류율   dropped  판정');
  let firstFail = null;
  STEPS.forEach((scale, i) => {
    const step = i + 1;
    const p99 = val(`http_req_duration{step:${step}}`, 'p(99)');
    const err = val(`http_req_failed{step:${step}}`, 'rate');
    const dropped = Object.keys(APIS).reduce((a, api) => a + val(`dropped_iterations{scenario:s${step}_${api}}`, 'count'), 0);
    const why = [p99 > P99_MS && `p99 ${ms(p99)} > ${P99_MS}ms`, err >= 0.01 && `오류율 ${(err * 100).toFixed(2)}% ≥ 1%`, dropped > 0 && `dropped ${dropped}`].filter(Boolean);
    if (why.length && !firstFail) firstFail = `단계 ${step} (${Math.round(TOTAL * scale)} RPS): ${why.join(', ')}`;
    lines.push(`  ${String(step).padEnd(3)} ${String(Math.round(TOTAL * scale)).padStart(7)} ${(val(`http_reqs{step:${step}}`, 'count') / STEP_SECONDS).toFixed(1).padStart(8)} ${ms(p99).padStart(6)} ${(err * 100).toFixed(2).padStart(7)}% ${String(dropped).padStart(8)}  ${why.length ? '실패' : '통과'}`);
  });
  lines.push('', firstFail ? `처음 실패한 단계: ${firstFail}` : '모든 단계 통과', '');
  return { stdout: lines.join('\n') };
}
