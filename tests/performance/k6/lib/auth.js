// member-service 로그인·갱신. 토큰은 VU 메모리에만 둔다.
//
// 액세스 토큰은 15분이고, 모든 인증 요청이 member 의 세션 확인을 거친다(설계안 8장 리스크).
// 그래서 로그인 자체도 부하의 일부로 센다: 시나리오마다 VU 가 자기 첫 반복에서 로그인한다.
import { check } from 'k6';
import { api } from './config.js';
import { postJson, unwrap, getJson } from './http.js';

const SKEW_SECONDS = 60; // Frontend 와 같이 만료 1분 전에 갱신한다

export function login(email, password) {
  const res = postJson(api('member', '/v1/auth/login'), { email, password }, {}, { tags: { name: 'login' } });
  check(res, { 'login 200': (r) => r.status === 200 });
  const pair = unwrap(res);
  if (!pair) throw new Error(`login failed for ${email}: ${res.status} ${res.body && res.body.slice(0, 200)}`);
  return session(pair);
}

export function refresh(current) {
  const res = postJson(api('member', '/v1/auth/refresh'), { refreshToken: current.refreshToken }, {}, { tags: { name: 'refresh' } });
  check(res, { 'refresh 200': (r) => r.status === 200 });
  const pair = unwrap(res);
  if (!pair) throw new Error(`refresh failed: ${res.status}`);
  return session(pair);
}

// 만료가 가까우면 갱신한 세션을, 아니면 그대로 돌려준다.
export function fresh(current) {
  if (Date.now() / 1000 > current.expiresAt - SKEW_SECONDS) return refresh(current);
  return current;
}

export function bearer(current) {
  return { Authorization: `Bearer ${current.accessToken}` };
}

export function me(current) {
  return unwrap(getJson(api('member', '/v1/members/me'), bearer(current), { tags: { name: 'me' } }));
}

function session(pair) {
  return {
    accessToken: pair.accessToken,
    refreshToken: pair.refreshToken,
    expiresAt: Date.now() / 1000 + Number(pair.expiresIn || 900),
  };
}
