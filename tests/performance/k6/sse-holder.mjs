#!/usr/bin/env node
// SSE 연결 N 개를 열어 둔 채 유지한다. Node 22 이상, 외부 패키지 없음.
//
//   node tests/performance/k6/sse-holder.mjs --count 500 --base http://localhost:9080 [--ramp 30] [--hold 180]
//
// 왜 따로 두나: 기본 k6 는 SSE 를 못 연다(xk6-sse 확장 필요). 그래서 "열린 연결 수"만 담당하는 스크립트를
// k6 옆에서 돌린다. 5초마다 열린 연결 수·끊긴 수·받은 이벤트 수를 찍는다. 시나리오 3(Redis 장애)에서는
// 이 로그로 SSE 가 끊기는지, 끊기면 몇 초 뒤 다시 붙는지 본다.
//
// 연결은 브라우저 EventSource 처럼 Accept: text/event-stream 으로 GET 하고 본문을 읽기만 한다.
// 끊기면 3초 뒤 다시 연다(EventSource 기본 동작과 같다). 연결 수는 live 의 shoppinglive_live_sse_connections 와
// 맞아야 한다(여러 live 파드면 합계).
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = parse(process.argv.slice(2));
const BASE = (args.base || process.env.BASE_URL || 'http://localhost:9080').replace(/\/$/, '');
const COUNT = Number(args.count || 100);
const RAMP = Number(args.ramp || 30);  // 초. 이 시간에 걸쳐 COUNT 개를 연다
const HOLD = Number(args.hold || 180); // 초. 다 연 뒤 유지하는 시간
const RECONNECT_MS = 3000;
const here = dirname(fileURLToPath(import.meta.url));

const state = { open: 0, opened: 0, closed: 0, events: 0, errors: 0, reconnects: 0, stopping: false };

async function broadcastId() {
  if (args.broadcast) return args.broadcast;
  const seed = JSON.parse(await readFile(resolve(args.seed || `${here}/.seed/seed.json`), 'utf8'));
  return seed.broadcastId;
}

async function hold(url, n) {
  while (!state.stopping) {
    const ac = new AbortController();
    try {
      const res = await fetch(url, { headers: { Accept: 'text/event-stream', 'Cache-Control': 'no-cache' }, signal: ac.signal });
      if (res.status !== 200 || !res.body) { state.errors++; await sleep(RECONNECT_MS); continue; }
      state.open++; state.opened++;
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        // 이벤트는 빈 줄로 끝난다. 주석 줄(":")은 heartbeat 라 세지 않는다.
        let idx;
        while ((idx = buffer.indexOf('\n\n')) >= 0) {
          const chunk = buffer.slice(0, idx); buffer = buffer.slice(idx + 2);
          if (chunk.split('\n').some((l) => l.startsWith('data:') || l.startsWith('event:'))) state.events++;
        }
      }
      state.open--; state.closed++;
    } catch (e) {
      if (state.open > 0 && !ac.signal.aborted) { state.open--; state.closed++; }
      if (!state.stopping) state.errors++;
    }
    if (state.stopping) return;
    state.reconnects++;
    await sleep(RECONNECT_MS);
  }
}

function report(tag) {
  console.log(`${new Date().toISOString()} ${tag} open=${state.open} opened=${state.opened} closed=${state.closed} reconnects=${state.reconnects} errors=${state.errors} events=${state.events}`);
}

async function main() {
  const id = await broadcastId();
  const url = `${BASE}/api/live/v1/broadcasts/${id}/events`;
  console.log(`SSE 연결 유지: 연결 수=${COUNT} 주소=${url} 연결 증가 시간=${RAMP}초 유지 시간=${HOLD}초`);
  const ticker = setInterval(() => report('tick'), 5000);
  const tasks = [];
  const gap = (RAMP * 1000) / COUNT;
  for (let n = 0; n < COUNT; n++) {
    tasks.push(hold(url, n));
    await sleep(gap);
  }
  await sleep(HOLD * 1000);
  state.stopping = true;
  clearInterval(ticker);
  report('done');
  process.exit(0);
}

process.on('SIGINT', () => { state.stopping = true; report('interrupted'); process.exit(0); });

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
function parse(argv) {
  const o = {};
  for (let i = 0; i < argv.length; i++) if (argv[i].startsWith('--')) o[argv[i].slice(2)] = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
  return o;
}

main().catch((e) => { console.error(e.message || e); process.exit(1); });
