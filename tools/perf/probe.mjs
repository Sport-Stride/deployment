#!/usr/bin/env node
// Active latency probe for read-only (GET) endpoints through the Next.js proxy (/api/proxy/<service>/<path>).
// Env: PERF_BASE_URL (default https://app.coachify.tn), PERF_EMAIL, PERF_PASSWORD (dedicated test account),
//      PERF_CLIENT_ID, PERF_COACH_ID (substituted into {clientId} / {coachId}).
// Flags: --n 15 --concurrency 3 --config endpoints.json --filter substr --service name --json
//        --repeat-slowest (rerun slowest 5 with N=50) --dry-run
// Exit: 0 ok, 1 budget/status violation, 2 setup error (login, config).
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { percentile } from './latency-report.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_P95 = 800;
const TIMEOUT_MS = 30000;

function parseArgs(argv) {
  const a = { n: 15, concurrency: 3, config: path.join(HERE, 'endpoints.json'), filter: '', service: '', json: false, repeat: false, dry: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => { if (i + 1 >= argv.length) throw new Error(`missing value for ${k}`); return argv[++i]; };
    if (k === '--n') a.n = Number(v());
    else if (k === '--concurrency') a.concurrency = Number(v());
    else if (k === '--config') a.config = v();
    else if (k === '--filter') a.filter = v().toLowerCase();
    else if (k === '--service') a.service = v();
    else if (k === '--json') a.json = true;
    else if (k === '--repeat-slowest') a.repeat = true;
    else if (k === '--dry-run') a.dry = true;
    else if (k === '-h' || k === '--help') a.help = true;
    else throw new Error(`unknown flag ${k}`);
  }
  if (!(a.n >= 1) || !(a.concurrency >= 1)) throw new Error('--n and --concurrency must be >= 1');
  return a;
}

export function resolvePath(p, vars) {
  const missing = [];
  const out = p.replace(/\{(\w+)\}/g, (_, k) => {
    const val = vars[k];
    if (!val) { missing.push(k); return ''; }
    return encodeURIComponent(val);
  });
  return { path: out, missing };
}

export function expectedList(e) {
  return Array.isArray(e.expectStatus) ? e.expectStatus : [e.expectStatus ?? 200];
}

export function buildPlan(endpoints, vars, a) {
  const plan = [];
  for (const e of endpoints) {
    if (e.method && e.method.toUpperCase() !== 'GET') throw new Error(`${e.name}: only GET is allowed`);
    if (a.service && e.service !== a.service) continue;
    if (a.filter && !`${e.name} ${e.path}`.toLowerCase().includes(a.filter)) continue;
    const { path: p, missing } = resolvePath(e.path, vars);
    const skip = e.enabled === false ? 'disabled' : missing.length ? `missing env for {${missing.join('},{')}}` : null;
    plan.push({ ...e, resolved: p, url: `/api/proxy/${e.service}${p.startsWith('/') ? '' : '/'}${p}`, skip, budget: e.budgetP95Ms ?? DEFAULT_P95 });
  }
  return plan;
}

async function login(base, email, password) {
  const res = await fetch(`${base}/api/proxy/account/user/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`login failed: HTTP ${res.status}${typeof data?.error === 'string' ? ' ' + data.error : ''}`);
  const token = data?.user?.token || data?.token;
  if (!token) throw new Error('login returned no token');
  return token;
}

async function hit(base, token, ep) {
  const t0 = performance.now();
  try {
    const res = await fetch(base + ep.url, {
      method: 'GET',
      headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' },
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    const buf = await res.arrayBuffer();
    return { ms: performance.now() - t0, status: res.status, bytes: buf.byteLength };
  } catch (e) {
    return { ms: performance.now() - t0, status: 0, bytes: 0, error: e.name === 'TimeoutError' ? 'timeout' : 'network' };
  }
}

async function runEndpoint(base, token, ep, n, concurrency) {
  await hit(base, token, ep); // warm-up, discarded
  const results = [];
  let next = 0;
  const worker = async () => {
    while (next < n) { next++; results.push(await hit(base, token, ep)); }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, n) }, worker));
  return summarize(ep, results);
}

export function summarize(ep, results) {
  const lat = results.map((r) => r.ms).sort((x, y) => x - y);
  const statuses = {};
  for (const r of results) statuses[r.status] = (statuses[r.status] || 0) + 1;
  const ok = expectedList(ep);
  const unexpected = results.filter((r) => !ok.includes(r.status)).length;
  const p95 = percentile(lat, 95);
  const flags = [];
  if (p95 > ep.budget) flags.push('P95');
  if (unexpected) flags.push('STATUS');
  return {
    name: ep.name, service: ep.service, url: ep.url, n: results.length, statuses, unexpected,
    avgBytes: Math.round(results.reduce((s, r) => s + r.bytes, 0) / (results.length || 1)),
    p50: percentile(lat, 50), p95, max: lat.length ? lat[lat.length - 1] : 0, budget: ep.budget, flags,
  };
}

const f1 = (n) => (n >= 100 ? n.toFixed(0) : n.toFixed(1));
function table(rows) {
  const head = ['endpoint', 'n', 'status', 'p50', 'p95', 'max', 'budget', 'KB', 'flags'];
  const cells = [head, ...rows.map((r) => [
    r.name, String(r.n), Object.entries(r.statuses).map(([s, c]) => `${s}x${c}`).join(' '),
    f1(r.p50), f1(r.p95), f1(r.max), String(r.budget), (r.avgBytes / 1024).toFixed(1), r.flags.join(','),
  ])];
  const w = head.map((_, i) => Math.max(...cells.map((c) => c[i].length)));
  const num = new Set([1, 3, 4, 5, 6, 7]);
  return cells.map((c) => c.map((v, i) => (num.has(i) ? v.padStart(w[i]) : v.padEnd(w[i]))).join('  ').trimEnd()).join('\n');
}

async function main() {
  let a;
  try { a = parseArgs(process.argv.slice(2)); } catch (e) { console.error(e.message); process.exit(2); }
  if (a.help) { console.log('node probe.mjs [--n 15] [--concurrency 3] [--config F] [--filter s] [--service s] [--repeat-slowest] [--json] [--dry-run]'); return; }

  const base = (process.env.PERF_BASE_URL || 'https://app.coachify.tn').replace(/\/+$/, '');
  const vars = { clientId: process.env.PERF_CLIENT_ID, coachId: process.env.PERF_COACH_ID };
  let plan;
  try { plan = buildPlan(JSON.parse(readFileSync(a.config, 'utf8')), vars, a); } catch (e) { console.error(`config error: ${e.message}`); process.exit(2); }

  const runnable = plan.filter((p) => !p.skip);
  if (a.dry) {
    console.log(`base=${base} n=${a.n} concurrency=${a.concurrency} warmup=1 repeatSlowest=${a.repeat}`);
    console.log(`credentials: ${process.env.PERF_EMAIL && process.env.PERF_PASSWORD ? 'PERF_EMAIL/PERF_PASSWORD set' : 'PERF_EMAIL/PERF_PASSWORD NOT set'}`);
    for (const p of plan) {
      console.log(`${p.skip ? 'SKIP' : 'RUN '}  GET ${p.url}  expect=${expectedList(p).join('|')} p95<=${p.budget}ms  [${p.name}]${p.skip ? '  (' + p.skip + ')' : ''}`);
    }
    console.log(`${runnable.length} to run, ${plan.length - runnable.length} skipped, ${runnable.length * (a.n + 1)} requests`);
    return;
  }

  if (!process.env.PERF_EMAIL || !process.env.PERF_PASSWORD) { console.error('PERF_EMAIL and PERF_PASSWORD are required'); process.exit(2); }
  let token;
  try { token = await login(base, process.env.PERF_EMAIL, process.env.PERF_PASSWORD); } catch (e) { console.error(e.message); process.exit(2); }

  const results = [];
  for (const ep of runnable) results.push({ ep, r: await runEndpoint(base, token, ep, a.n, a.concurrency) });
  let rows = results.map((x) => x.r);

  let repeated = [];
  if (a.repeat) {
    const slowest = [...results].sort((x, y) => y.r.p95 - x.r.p95).slice(0, 5);
    for (const s of slowest) {
      const r = await runEndpoint(base, token, s.ep, 50, a.concurrency);
      repeated.push(r);
      rows = rows.map((x) => (x.name === r.name ? { ...r, rerun: true } : x));
    }
  }

  rows.sort((x, y) => y.p95 - x.p95);
  const bad = rows.filter((r) => r.flags.length);
  if (a.json) console.log(JSON.stringify({ base, n: a.n, rows, skipped: plan.filter((p) => p.skip).map((p) => ({ name: p.name, reason: p.skip })) }, null, 2));
  else {
    console.log(`base=${base} n=${a.n} concurrency=${a.concurrency} (ms, worst p95 first)`);
    console.log(table(rows));
    if (repeated.length) console.log(`\nrerun with N=50 (replaced above): ${repeated.map((r) => r.name).join('; ')}`);
    const skipped = plan.filter((p) => p.skip);
    if (skipped.length) console.log(`\nskipped ${skipped.length}: ` + skipped.map((p) => `${p.name} (${p.skip})`).join('; '));
    console.log(`\n${bad.length} endpoint(s) over budget or with unexpected status`);
  }
  process.exit(bad.length ? 1 : 0);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => { console.error(e.message); process.exit(2); });
}
