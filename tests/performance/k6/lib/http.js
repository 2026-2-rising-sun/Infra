// 응답 봉투 처리. Backend 는 모든 JSON 응답을 { success, data, error } 로 감싼다.
import http from 'k6/http';
import { jsonHeaders } from './config.js';

export function unwrap(res) {
  try {
    const body = res.json();
    return body && body.success ? body.data : null;
  } catch (e) {
    return null;
  }
}

export function errorCode(res) {
  try {
    const body = res.json();
    return body && body.error ? body.error.code : null;
  } catch (e) {
    return null;
  }
}

export function postJson(url, body, headers = {}, params = {}) {
  return http.post(url, JSON.stringify(body), { ...params, headers: { ...jsonHeaders, ...headers } });
}

export function getJson(url, headers = {}, params = {}) {
  return http.get(url, { ...params, headers: { Accept: 'application/json', ...headers } });
}
