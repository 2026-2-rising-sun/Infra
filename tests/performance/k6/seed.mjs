#!/usr/bin/env node
// 부하 테스트용 데이터를 만든다. Node 22 이상, 외부 패키지 없음.
//
//   node tests/performance/k6/seed.mjs --base http://localhost:9080 --users 200 --limit 100
//
// 만드는 것
//   1) 테스트 사용자 N 명: loadtest-<n>@load.test (회원가입 API). 이미 있으면 그대로 쓴다.
//   2) 방송 1개: 판매자(seller/seller, local 테스트 계정)가 등록. 상태는 "예정"으로 두고 시작은 시나리오 1 이 한다.
//   3) 쿠폰 1개: 발급 한도 --limit (기본 사용자 수의 절반). 시나리오 2 가 한도 초과를 보려고 일부러 작게 둔다.
//   4) 방송 알림 신청: 사용자 전원이 2)의 방송에 신청 → 시나리오 1 에서 방송 시작 시 N 건 발송이 일어난다.
// 결과는 .seed/seed.json 에 쓴다(비밀번호가 들어 있으니 커밋하지 않는다).
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const args = parse(process.argv.slice(2));
const BASE = (args.base || process.env.BASE_URL || 'http://localhost:9080').replace(/\/$/, '');
const USERS = Number(args.users || 50);
const LIMIT = Number(args.limit || Math.max(1, Math.floor(USERS / 2)));
const CONCURRENCY = Number(args.concurrency || 10);
const PASSWORD = args.password || 'LoadTest-2026!';
const SELLER = { email: args.seller || 'seller@local.test', password: args['seller-password'] || 'seller' };
const here = dirname(fileURLToPath(import.meta.url));
const OUT = resolve(args.out || `${here}/.seed/seed.json`);

const api = (service, path) => `${BASE}/api/${service}${path}`;

async function call(method, url, { body, token, headers = {} } = {}) {
  const res = await fetch(url, {
    method,
    headers: { Accept: 'application/json', ...(body ? { 'Content-Type': 'application/json' } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* 본문이 JSON 이 아닐 수 있다 */ }
  return { status: res.status, json, data: json && json.success ? json.data : null, text };
}

async function login(email, password) {
  const r = await call('POST', api('member', '/v1/auth/login'), { body: { email, password } });
  if (!r.data) throw new Error(`로그인 실패: 계정=${email} 상태 코드=${r.status} ${r.text.slice(0, 200)}`);
  return r.data.accessToken;
}

async function ensureUser(i) {
  const email = `loadtest-${i}@load.test`;
  const r = await call('POST', api('member', '/v1/auth/signup'), { body: { email, password: PASSWORD, displayName: `부하테스트 ${i}` } });
  if (r.status !== 201 && r.status !== 409) throw new Error(`회원가입 실패: 계정=${email} 상태 코드=${r.status} ${r.text.slice(0, 200)}`);
  return { email, password: PASSWORD };
}

async function firstProductId(sellerToken) {
  const r = await call('GET', api('shopping', '/v1/products?size=1'), { token: sellerToken });
  const id = r.data && r.data.items && r.data.items[0] && r.data.items[0].id;
  if (!id) throw new Error('쿠폰에 붙일 상품이 없다. 먼저 판매자 화면이나 make setup 의 시드로 상품을 하나 만든다.');
  return id;
}

async function createBroadcast(sellerToken) {
  const scheduledAt = new Date(Date.now() + 10 * 60 * 1000).toISOString(); // 10분 뒤 예정: "곧 시작할 방송" 지표에 잡힌다
  const r = await call('POST', api('live', '/v1/seller/broadcasts'), {
    token: sellerToken,
    headers: { 'Idempotency-Key': `loadtest-${randomUUID()}` },
    body: { title: `부하 테스트 ${new Date().toISOString().slice(0, 16)}`, scheduledAt, channelArn: 'arn:aws:ivs:ap-northeast-2:000000000000:channel/loadtest', playbackUrl: 'https://stub.invalid/loadtest/playlist.m3u8', hostName: '부하 테스트' },
  });
  if (!r.data) throw new Error(`방송 생성 실패: 상태 코드=${r.status} ${r.text.slice(0, 200)}`);
  return r.data.id;
}

async function createCoupon(sellerToken, productId) {
  const now = Date.now();
  const r = await call('POST', api('commerce', '/v1/seller/coupons'), {
    token: sellerToken,
    body: {
      name: `드롭 ${new Date(now).toISOString().slice(0, 16)}`,
      fixedDiscount: 1000,
      issuanceLimit: LIMIT,
      startsAt: new Date(now - 60_000).toISOString(),
      endsAt: new Date(now + 6 * 3600_000).toISOString(),
      expiresAt: new Date(now + 24 * 3600_000).toISOString(),
      productIds: [productId],
    },
  });
  if (!r.data) throw new Error(`쿠폰 생성 실패: 상태 코드=${r.status} ${r.text.slice(0, 200)}`);
  return r.data.id;
}

async function subscribeAlert(user, broadcastId) {
  const token = await login(user.email, user.password);
  const r = await call('POST', api('notification', '/v1/broadcast-alerts'), { token, body: { broadcastId } });
  if (r.status !== 201 && r.status !== 409 && r.status !== 200) throw new Error(`알림 신청 실패: 계정=${user.email} 상태 코드=${r.status} ${r.text.slice(0, 200)}`);
}

async function pool(items, worker) {
  const out = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(CONCURRENCY, items.length) }, async () => {
    while (next < items.length) { const i = next++; out[i] = await worker(items[i], i); }
  }));
  return out;
}

function parse(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
  return o;
}

// 시나리오 5 전용: --products N 이면 위 1)~4) 대신 판매 중 상품 N 개와 앞 --coupon-products 개 상품에 붙는 쿠폰 1개를 만들어
// .seed/products.json 에 쓴다. 이미지는 1장을 모든 상품이 같이 쓴다. 실행할 때마다 새 상품을 만든다.
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF1cAAAAASUVORK5CYII=', 'base64');

async function seedProducts(count) {
  const token = await login(SELLER.email, SELLER.password);
  const form = new FormData();
  form.append('file', new Blob([PNG], { type: 'image/png' }), 'loadtest.png');
  const img = await fetch(api('shopping', '/v1/seller/product-images'), { method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: form });
  const imageId = img.ok && (await img.json()).data.imageId;
  if (!imageId) throw new Error(`이미지 업로드 실패: 상태 코드=${img.status}`);

  const run = randomUUID().slice(0, 8);
  const productIds = await pool(Array.from({ length: count }, (_, i) => i + 1), async (i) => {
    const p = await call('POST', api('shopping', '/v1/seller/products'), { token, headers: { 'X-Idempotency-Key': `loadtest-${run}-${i}` }, body: { name: `부하 테스트 상품 ${i}`, description: '시나리오 5 혼합 조회용', mainImageId: imageId } });
    if (!p.data) throw new Error(`상품 등록 실패: 상태 코드=${p.status} ${p.text.slice(0, 200)}`);
    // 판매정보 API 는 응답 봉투가 없다.
    const s = await call('POST', api('commerce', '/v1/sales'), { token, body: { productId: p.data.productId, price: 10000, initialStock: 100000 } });
    if (!s.json || !s.json.id) throw new Error(`판매정보 등록 실패: 상품 ID=${p.data.productId} 상태 코드=${s.status} ${s.text.slice(0, 200)}`);
    const st = await call('PATCH', api('commerce', `/v1/sales/${s.json.id}/status`), { token, body: { status: 'ON_SALE' } });
    if (st.status !== 200) throw new Error(`판매 시작 실패: 상품 ID=${p.data.productId} 상태 코드=${st.status} ${st.text.slice(0, 200)}`);
    return p.data.productId;
  });
  console.log(`판매 중 상품 준비 완료: 상품 수=${productIds.length}`);

  const couponProducts = productIds.slice(0, Number(args['coupon-products'] || 100));
  const now = Date.now();
  const c = await call('POST', api('commerce', '/v1/seller/coupons'), {
    token,
    body: { name: `시나리오5 ${new Date(now).toISOString().slice(0, 16)}`, fixedDiscount: 1000, issuanceLimit: 100000, startsAt: new Date(now - 60_000).toISOString(), endsAt: new Date(now + 7 * 24 * 3600_000).toISOString(), expiresAt: new Date(now + 8 * 24 * 3600_000).toISOString(), productIds: couponProducts },
  });
  if (!c.data) throw new Error(`쿠폰 생성 실패: 상태 코드=${c.status} ${c.text.slice(0, 200)}`);
  console.log(`쿠폰 ID=${c.data.id} 적용 상품 수=${couponProducts.length}`);

  const out = resolve(args.out || `${here}/.seed/products.json`);
  await mkdir(dirname(out), { recursive: true });
  // 쿠폰이 붙은 상품이 앞에 온다. 시나리오 5 의 FOCUS=1 은 첫 상품을 쓴다.
  await writeFile(out, JSON.stringify({ createdAt: new Date().toISOString(), base: BASE, couponId: c.data.id, couponProductCount: couponProducts.length, productIds }, null, 2));
  console.log(`시드 파일 저장 완료: ${out}`);
}

async function main() {
  if (args.products) return seedProducts(Number(args.products === true ? 1000 : args.products));
  let previous = null;
  try { previous = JSON.parse(await readFile(OUT, 'utf8')); } catch { /* 처음 */ }

  console.log(`기준 주소=${BASE} 사용자 수=${USERS} 쿠폰 발급 한도=${LIMIT}`);
  const sellerToken = await login(SELLER.email, SELLER.password);
  const users = await pool(Array.from({ length: USERS }, (_, i) => i + 1), ensureUser);
  console.log(`사용자 준비 완료: 사용자 수=${users.length}`);

  // 방송은 매번 새로 만든다. 지난 실행의 방송은 이미 시작됐거나 끝났을 수 있다.
  const broadcastId = await createBroadcast(sellerToken);
  const productId = await firstProductId(sellerToken);
  const couponId = args['reuse-coupon'] && previous ? previous.couponId : await createCoupon(sellerToken, productId);
  console.log(`방송 ID=${broadcastId} 쿠폰 ID=${couponId} 상품 ID=${productId}`);

  await pool(users, (u) => subscribeAlert(u, broadcastId));
  console.log(`알림 신청 완료: 신청자 수=${users.length}`);

  const seed = { createdAt: new Date().toISOString(), base: BASE, broadcastId, couponId, couponLimit: LIMIT, productId, sellerEmail: SELLER.email, sellerPassword: SELLER.password, users };
  await mkdir(dirname(OUT), { recursive: true });
  await writeFile(OUT, JSON.stringify(seed, null, 2), { mode: 0o600 });
  console.log(`시드 파일 저장 완료: ${OUT}`);
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
