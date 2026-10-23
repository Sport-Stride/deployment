#!/usr/bin/env node
// Self test for latency-report parser/aggregator. Run: node tools/perf/selftest.mjs
import assert from 'node:assert/strict';
import { parseRequestLine, Aggregator, percentile, classifyEvent } from './latency-report.mjs';
import { buildPlan, summarize } from './probe.mjs';

let n = 0;
const t = (name, fn) => { fn(); n++; console.log('ok  ' + name); };

const err = '2026-10-23T15:14:01.753Z\tERROR\tutils/gin_zap.go:52\trequest\t{"status": 500, "method": "GET", "path": "/subscriptions/billing/clients/info", "route": "/subscriptions/billing/clients/info", "latency_ms": 12.3}';
const info = '2026-10-23T15:14:02.000Z\tINFO\tgin@v1.10.1/context.go:185\trequest completed\t{"status":200,"method":"GET","path":"/workouts/abc123","route":"/workouts/:id","latency_ms":0.257}';

t('parse error format', () => {
  const r = parseRequestLine(err);
  assert.equal(r.status, 500); assert.equal(r.method, 'GET'); assert.equal(r.latencyMs, 12.3);
  assert.equal(r.level, 'ERROR');
});
t('parse info format, route collapses ids', () => {
  const r = parseRequestLine(info);
  assert.equal(r.route, '/workouts/:id'); assert.equal(r.latencyMs, 0.257);
});
t('malformed / non-request lines return null', () => {
  assert.equal(parseRequestLine('garbage'), null);
  assert.equal(parseRequestLine('2026\tINFO\tx.go:1\tstarting\t{"port": 8080}'), null);
  assert.equal(parseRequestLine('2026\tINFO\tx.go:1\trequest\t{"status": 200, "method": "GET", "latency_ms": 1'), null);
  assert.equal(parseRequestLine(''), null);
});
t('missing latency parsed as null', () => {
  const r = parseRequestLine('2026\tINFO\tx\trequest\t{"status":200,"method":"GET","route":"/a"}');
  assert.equal(r.latencyMs, null);
});
t('percentile nearest-rank', () => {
  const s = Array.from({ length: 100 }, (_, i) => i + 1);
  assert.equal(percentile(s, 50), 50); assert.equal(percentile(s, 95), 95);
  assert.equal(percentile(s, 99), 99); assert.equal(percentile([], 95), 0);
  assert.equal(percentile([7], 99), 7);
});

const line = (status, route, lat, method = 'GET') =>
  `2026-10-23T10:00:00.000Z\tINFO\tgin.go:1\trequest completed\t{"status":${status},"method":"${method}","path":"${route}","route":"${route}","latency_ms":${lat}}`;

t('aggregate, percentiles, error rates, budget flags, ignore', () => {
  const agg = new Aggregator(['/health', '/metrics']);
  for (let i = 1; i <= 100; i++) agg.add('payments-api', line(i <= 2 ? 500 : i <= 12 ? 404 : 200, '/slow', i * 10));
  for (let i = 0; i < 50; i++) agg.add('payments-api', line(200, '/fast', 5));
  for (let i = 0; i < 5; i++) agg.add('payments-api', line(200, '/health', 9999));
  agg.add('payments-api', line(200, '/metrics/x', 9999));
  agg.add('payments-api', 'not a log line latency_ms');
  agg.add('payments-api', '2026\tINFO\tx\trequest\t{"status":200,"method":"GET","route":"/nolat"}');
  const budgets = { default: { p95Ms: 800, p99Ms: 2000, maxMs: 10000, errorRate5xx: 0.01 }, routes: { 'GET /fast': { p95Ms: 1 } } };
  const rows = agg.rows(budgets);
  const slow = rows.find((r) => r.route === '/slow');
  assert.equal(slow.count, 100); assert.equal(slow.p50, 500); assert.equal(slow.p95, 950); assert.equal(slow.p99, 990); assert.equal(slow.max, 1000);
  assert.equal(slow.e5xx, 2); assert.equal(slow.e4xx, 10); assert.ok(Math.abs(slow.rate5xx - 0.02) < 1e-9);
  assert.deepEqual(slow.flags, ['P95', '5XX']);
  const fast = rows.find((r) => r.route === '/fast');
  assert.deepEqual(fast.flags, ['P95']); // override p95Ms=1, 5ms > 1
  assert.equal(rows[0].route, '/slow'); // worst p95 first
  assert.ok(!rows.some((r) => r.route.startsWith('/health') || r.route.startsWith('/metrics')));
  assert.equal(agg.stats.ignored, 6);
  assert.equal(agg.stats.noLatency, 1);
  assert.equal(agg.stats.malformed, 1);
  assert.equal(rows.find((r) => r.route === '/nolat').count, 1);
  const share = rows.reduce((a, r) => a + r.timeShare, 0);
  assert.ok(Math.abs(share - 1) < 1e-9);
});
t('p99 and max flags', () => {
  const agg = new Aggregator();
  for (let i = 0; i < 98; i++) agg.add('s', line(200, '/x', 10));
  agg.add('s', line(200, '/x', 2500)); agg.add('s', line(200, '/x', 12000));
  const r = agg.rows({}).find((x) => x.route === '/x');
  assert.deepEqual(r.flags, ['P99', 'MAX']);
});
t('same route different service/method grouped separately', () => {
  const agg = new Aggregator();
  agg.add('a', line(200, '/r', 1)); agg.add('b', line(200, '/r', 1)); agg.add('a', line(200, '/r', 1, 'POST'));
  assert.equal(agg.rows({}).length, 3);
});
t('event detection and scrubbing', () => {
  assert.equal(classifyEvent('2026\tERROR\tx\tmongo failed\t{"error":"context deadline exceeded"}'), 'deadline');
  assert.equal(classifyEvent('2026\tERROR\tx\tpanic recovered\t{}'), 'panic');
  assert.equal(classifyEvent('2026\tINFO\tx\tconfig\t{"timeout":"10s"}'), null);
  assert.equal(classifyEvent('2026\tWARN\tx\thttp call\t{"error":"request timeout"}'), 'timeout');
  const agg = new Aggregator();
  agg.add('s', '2026\tERROR\tx\tfail\t{"error":"context deadline exceeded","email":"a.b@x.com"}');
  agg.add('s', '2026\tERROR\tx\tfail\t{"error":"context deadline exceeded","email":"c@y.com"}');
  const ev = agg.eventsList()[0];
  assert.equal(ev.deadline, 2); assert.equal(ev.samples.length, 1); assert.equal(ev.samples[0].n, 2);
  assert.ok(!ev.samples[0].sample.includes('@x.com'));
});

t('duration-string latency and id collapse when no route field', () => {
  const r = parseRequestLine('2026\tDEBUG\tx\trequest\t{"method": "GET", "path": "/user/1209995689703932?a=b", "status": 200, "latency": "1.5ms"}');
  assert.equal(r.latencyMs, 1.5); assert.equal(r.route, '/user/:id');
  assert.ok(Math.abs(parseRequestLine('2026\tD\tx\trequest\t{"method":"GET","path":"/a","status":200,"latency":"250µs"}').latencyMs - 0.25) < 1e-9);
  assert.equal(parseRequestLine('2026\tD\tx\trequest\t{"method":"GET","path":"/a","status":200,"latency":"2s"}').latencyMs, 2000);
});
t('secrets in query strings are scrubbed from event samples', () => {
  const agg = new Aggregator();
  agg.add('s', '2026/10/23 [ERROR] dial: Get "https://h:443?key=SECRETKEY&x=1": context deadline exceeded');
  assert.ok(!agg.eventsList()[0].samples[0].sample.includes('SECRETKEY'));
});

t('probe plan: substitution, skip on missing env, GET only, summarize flags', () => {
  const eps = [
    { name: 'a', method: 'GET', service: 'statistics', path: '/notes?client_id={clientId}', expectStatus: 200 },
    { name: 'b', method: 'GET', service: 'account', path: '/coach/clients', expectStatus: [200, 404], budgetP95Ms: 100 },
  ];
  const noEnv = buildPlan(eps, {}, {});
  assert.match(noEnv[0].skip, /clientId/); assert.equal(noEnv[1].skip, null);
  const plan = buildPlan(eps, { clientId: 'x y' }, {});
  assert.equal(plan[0].url, '/api/proxy/statistics/notes?client_id=x%20y');
  assert.throws(() => buildPlan([{ name: 'p', method: 'POST', service: 's', path: '/x' }], {}, {}));
  const mk = (ms, status) => ({ ms, status, bytes: 10 });
  const s = summarize(plan[1], [mk(50, 200), mk(60, 404), mk(300, 200), mk(70, 500)]);
  assert.deepEqual(s.flags, ['P95', 'STATUS']); assert.equal(s.unexpected, 1); assert.equal(s.max, 300);
});

console.log(`\n${n} tests passed`);
