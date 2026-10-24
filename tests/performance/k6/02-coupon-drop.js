// 시나리오 2: 선착순 쿠폰 드롭.
//
// 시청 중인 N 명이 같은 순간 쿠폰 발급을 누른다. 발급 한도(issuanceLimit)보다 사용자가 많게 시드해서
// 한도 초과가 실제로 일어나게 한다.
//
// 보는 것: commerce p99, DB 커넥션 풀 대기(Grafana 02 대시보드 Hikari pending), 중복 발급 0 건.
// 중복 발급 판정: 201 응답 수 ≤ 한도, 같은 사용자가 두 번 눌러도 두 번째는 200(이미 가짐)이어야 한다.
import { check, sleep } from 'k6';
import http from 'k6/http';
import { Counter } from 'k6/metrics';
import { USERS, api, thresholds } from './lib/config.js';
import { seed, userFor } from './lib/seed.js';
import { login, bearer } from './lib/auth.js';
import { postJson, errorCode } from './lib/http.js';

const issued = new Counter('coupon_issued');        // 201
const alreadyOwned = new Counter('coupon_already');  // 200
const exhausted = new Counter('coupon_exhausted');   // 409 CONFLICT (기간 또는 한도)
const unexpected = new Counter('coupon_unexpected'); // 그 외

// 사용자 수만큼 VU 를 만들고 각자 정확히 한 번 누른다. 전원이 같은 순간 시작하도록
// 로그인은 setup 이 아니라 각 VU 의 반복 시작 직전에 끝내고 잠깐 맞춘다(아래 ALIGN_MS).
const ALIGN_MS = Number(__ENV.ALIGN_MS || 3000);

export const options = {
  scenarios: {
    drop: {
      executor: 'per-vu-iterations',
      vus: USERS,
      iterations: Number(__ENV.CLICKS || 2), // 두 번째 클릭은 "이미 가진 쿠폰" 응답을 확인하는 용도
      maxDuration: '2m',
    },
  },
  thresholds: {
    ...thresholds,
    'http_req_duration{name:claim}': ['p(99)<1000'],
    coupon_unexpected: ['count==0'],
    coupon_issued: [`count<=${seed.couponLimit}`],
  },
  tags: { scenario: 'coupon-drop' },
};

export function setup() {
  if (!Number.isInteger(seed.couponLimit) || seed.couponLimit <= 0) {
    throw new Error('시드에 양수 couponLimit이 필요합니다.');
  }
  return { fireAt: Date.now() + ALIGN_MS + 5000 };
}

let owned = false;
let session = null; // VU 하나의 상태

export default function (data) {
  if (!session) {
    const u = userFor(__VU);
    session = login(u.email, u.password);
    // 모두 같은 시각에 누르게 맞춘다. 로그인이 느린 VU 는 늦게 누르는데, 그것도 현실과 같다.
    const wait = data.fireAt - Date.now();
    if (wait > 0) sleep(wait / 1000);
  }
  // 계약상 409 CONFLICT만 기간·수량 제한 응답이다. 인증·경로 오류는 실패로 남긴다.
  const res = postJson(api('commerce', `/v1/coupons/${seed.couponId}/claims`), {}, bearer(session), { tags: { name: 'claim' }, responseCallback: http.expectedStatuses(200, 201, 409) });
  const limited = res.status === 409 && errorCode(res) === 'CONFLICT';
  const valid = owned ? res.status === 200 : res.status === 201 || res.status === 200 || limited;
  unexpected.add(valid ? 0 : 1, { status: String(res.status) });
  issued.add(res.status === 201 ? 1 : 0);
  if (res.status === 200) alreadyOwned.add(1);
  if (limited) exhausted.add(1);
  if (res.status === 200 || res.status === 201) owned = true;
  check(res, { 'claim contract and retry are valid': () => valid });
}

export function handleSummary(data) {
  const n = (k) => (data.metrics[k] ? data.metrics[k].values.count : 0);
  const line = `coupon ${seed.couponId}: issued(201)=${n('coupon_issued')} already(200)=${n('coupon_already')} exhausted(4xx)=${n('coupon_exhausted')} unexpected=${n('coupon_unexpected')} limit=${seed.couponLimit}\n`;
  const over = seed.couponLimit && n('coupon_issued') > seed.couponLimit ? `!! 발급 수가 한도를 넘었다 (${n('coupon_issued')} > ${seed.couponLimit})\n` : '';
  return { stdout: line + over };
}
