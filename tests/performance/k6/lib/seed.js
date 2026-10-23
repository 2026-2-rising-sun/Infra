// seed.mjs 가 만든 파일을 VU 들이 공유해서 읽는다. SharedArray 는 VU 수만큼 복사되지 않는다.
import { SharedArray } from 'k6/data';
import { SEED_FILE } from './config.js';

function load() {
  return JSON.parse(open(SEED_FILE));
}

// users: [{ email, password }], broadcastId, couponId, sellerEmail, sellerPassword
export const seed = load();
export const users = new SharedArray('users', () => load().users);

// VU 번호로 사용자를 고정한다. VU 가 사용자보다 많으면 돌려 쓴다(같은 계정 중복 로그인은 허용된다).
export function userFor(vu) {
  return users[(vu - 1) % users.length];
}
