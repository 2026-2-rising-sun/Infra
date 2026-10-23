// 외부 요청 없이 실제 시나리오의 응답 분류와 재시도 판정을 실행한다.
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';

const source = await readFile(new URL('./02-coupon-drop.js', import.meta.url), 'utf8');
async function scenario(responses) {
  const counters = {};
  const sleeps = [];
  const context = vm.createContext({ __ENV: {}, __VU: 1, Date, console });
  const imports = {
    k6: { check: (res, checks) => Object.values(checks).every(fn => fn(res)), sleep: n => sleeps.push(n) },
    'k6/http': { default: { expectedStatuses: (...statuses) => statuses } },
    'k6/metrics': { Counter: class { constructor(name) { this.name = name; } add(n) { counters[this.name] = (counters[this.name] || 0) + n; } } },
    './lib/config.js': { USERS: 1, api: (service, path) => path, thresholds: {} },
    './lib/seed.js': { seed: { couponId: 'test', couponLimit: 1 }, userFor: () => ({ email: 'test', password: 'test' }) },
    './lib/auth.js': { login: () => ({}), bearer: () => ({}) },
    './lib/http.js': { postJson: () => responses.shift(), errorCode: res => res.code },
  };
  const module = new vm.SourceTextModule(source, { context });
  await module.link(name => {
    const values = imports[name];
    return new vm.SyntheticModule(Object.keys(values), function () {
      for (const [key, value] of Object.entries(values)) this.setExport(key, value);
    }, { context });
  });
  await module.evaluate();
  const count = responses.length;
  for (let i = 0; i < count; i++) module.namespace.default({ fireAt: Date.now() + 1000 });
  return { counters, sleeps, options: module.namespace.options };
}

test('신규 발급 후 재요청 200은 성공하고 대기는 sleep을 사용한다', async () => {
  const r = await scenario([{ status: 201 }, { status: 200 }]);
  assert.equal(r.counters.coupon_unexpected, 0);
  assert.equal(r.counters.coupon_issued, 1);
  assert.equal(r.sleeps.length, 1);
  assert.equal(r.options.thresholds.coupon_issued[0], 'count<=1');
});
for (const status of [401, 403, 404, 500]) {
  test(`${status} 응답은 쿠폰 소진으로 숨기지 않는다`, async () => {
    const r = await scenario([{ status }]);
    assert.equal(r.counters.coupon_unexpected, 1);
  });
}
test('계약의 CONFLICT만 제한 응답으로 인정한다', async () => {
  const valid = await scenario([{ status: 409, code: 'CONFLICT' }]);
  assert.equal(valid.counters.coupon_unexpected, 0);
  const invalid = await scenario([{ status: 409, code: 'OTHER' }]);
  assert.equal(invalid.counters.coupon_unexpected, 1);
});
test('같은 사용자의 두 번째 신규 발급은 실패한다', async () => {
  const r = await scenario([{ status: 201 }, { status: 201 }]);
  assert.equal(r.counters.coupon_unexpected, 1);
  assert.equal(r.counters.coupon_issued, 2);
});
