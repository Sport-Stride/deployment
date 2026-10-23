#!/usr/bin/env node
// Backend latency/error report from Go zap request logs.
// Usage: node latency-report.mjs [--host user@h] [--since 6h] [--services all|a,b] [--stdin]
//        [--service-name NAME] [--budgets file] [--top N] [--json|--markdown]
// Exit: 0 ok, 1 budget exceeded, 2 usage/ssh error.
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const ALL_SERVICES = [
  'account-api', 'chat-api', 'content-api', 'identifier-api', 'invitation-api',
  'notification-api', 'payments-api', 'statistics-api', 'tracker-api', 'workout-api',
];
export const DEFAULT_BUDGET = { p95Ms: 800, p99Ms: 2000, maxMs: 10000, errorRate5xx: 0.01 };
const DEFAULT_IGNORE = ['/health', '/metrics', '/api/metrics', '/status'];

// ---------- parsing ----------
// Returns { ts, level, method, route, status, latencyMs|null } or null (not a request line).
export function parseRequestLine(line) {
  if (!line || line.indexOf('{') < 0) return null;
  const obj = extractJson(line);
  if (!obj || typeof obj !== 'object') return null;
  const method = obj.method;
  const route = obj.route !== undefined ? obj.route : obj.path;
  const status = Number(obj.status);
  if (typeof method !== 'string' || !Number.isFinite(status) || status <= 0) return null;
  if (route === undefined || route === null) return null;
  const parts = line.split('\t');
  const lat = latencyOf(obj);
  const hasLat = lat !== null;
  return {
    ts: parts[0],
    level: parts[1],
    method: method.toUpperCase(),
    route: route === '' ? '(unmatched)' : (obj.route !== undefined ? String(route) : collapseIds(String(route))),
    status,
    latencyMs: hasLat ? lat : null,
  };
}

// latency_ms (number) preferred; fallback to Go duration string field `latency` (e.g. "59.999µs", "1.2s").
function latencyOf(obj) {
  const n = Number(obj.latency_ms);
  if (obj.latency_ms !== undefined && obj.latency_ms !== null && obj.latency_ms !== '' && Number.isFinite(n) && n >= 0) return n;
  if (typeof obj.latency === 'string') {
    const m = obj.latency.match(/^(\d+(?:\.\d+)?)(ns|µs|us|μs|ms|s)$/);
    if (m) return Number(m[1]) * { ns: 1e-6, 'µs': 1e-3, us: 1e-3, 'μs': 1e-3, ms: 1, s: 1000 }[m[2]];
  }
  return null;
}

// Routes logged without a `route` template: drop query string, collapse id-like segments.
function collapseIds(p) {
  return p.split('?')[0].split('/').map((s) => (/^(\d{6,}|[0-9a-f]{24}|[0-9a-f]{8}-[0-9a-f-]{27})$/i.test(s) ? ':id' : s)).join('/');
}

function extractJson(line) {
  // JSON object is the trailing field; try each '{' starting from the first.
  let i = line.indexOf('{');
  while (i >= 0) {
    try {
      return JSON.parse(line.slice(i).trim());
    } catch { /* try next brace */ }
    i = line.indexOf('{', i + 1);
  }
  return null;
}

const EVENT_ANY = /i\/o timeout|timed out|Client\.Timeout/i;
const EVENT_WARN = /\btimeout\b/i;
const WARN_LEVELS = new Set(['WARN', 'WARNING', 'ERROR', 'DPANIC', 'PANIC', 'FATAL']);

export function classifyEvent(line) {
  if (/\bpanic\b/i.test(line)) return 'panic';
  if (/context deadline exceeded/i.test(line)) return 'deadline';
  if (EVENT_ANY.test(line)) return 'timeout';
  const level = line.split('\t')[1];
  if (WARN_LEVELS.has(level) && EVENT_WARN.test(line)) return 'timeout';
  return null;
}

function scrub(line) {
  return line
    .replace(/\?[^\s"]+/g, '?<query>')
    .replace(/[\w.+-]+@[\w-]+\.[\w.-]+/g, '<email>')
    .replace(/(Bearer\s+)[\w.-]+/gi, '$1<redacted>')
    .replace(/("(?:token|password|authorization|refresh_token|access_token)"\s*:\s*")[^"]*/gi, '$1<redacted>')
    .slice(0, 260);
}

// ---------- aggregation ----------
export function percentile(sorted, p) {
  if (!sorted.length) return 0;
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length, Math.max(1, rank)) - 1];
}

export class Aggregator {
  constructor(ignore = DEFAULT_IGNORE) {
    this.ignore = ignore;
    this.groups = new Map();
    this.events = new Map(); // service -> {deadline,timeout,panic,samples}
    this.stats = { lines: 0, requests: 0, ignored: 0, noLatency: 0, malformed: 0 };
  }

  isIgnored(route) {
    return this.ignore.some((p) => route === p || route.startsWith(p + '/'));
  }

  add(service, line) {
    this.stats.lines++;
    const kind = classifyEvent(line);
    if (kind) this.addEvent(service, kind, line);
    const r = parseRequestLine(line);
    if (!r) {
      if (line.includes('latency_ms')) this.stats.malformed++;
      return;
    }
    if (this.isIgnored(r.route)) { this.stats.ignored++; return; }
    this.stats.requests++;
    const key = `${service}\t${r.method}\t${r.route}`;
    let g = this.groups.get(key);
    if (!g) {
      g = { service, method: r.method, route: r.route, count: 0, e5xx: 0, e4xx: 0, lat: [] };
      this.groups.set(key, g);
    }
    g.count++;
    if (r.status >= 500) g.e5xx++;
    else if (r.status >= 400) g.e4xx++;
    if (r.latencyMs === null) this.stats.noLatency++;
    else g.lat.push(r.latencyMs);
  }

  addEvent(service, kind, line) {
    let e = this.events.get(service);
    if (!e) { e = { deadline: 0, timeout: 0, panic: 0, samples: new Map() }; this.events.set(service, e); }
    e[kind]++;
    const s = scrub(line.replace(/^\S+\t/, ''));
    const k = s.replace(/\d+/g, '#').slice(0, 120);
    if (!e.samples.has(k) && e.samples.size < 5) e.samples.set(k, { kind, sample: s, n: 0 });
    const smp = e.samples.get(k);
    if (smp) smp.n++;
  }

  rows(budgets) {
    const totalTime = [...this.groups.values()].reduce((a, g) => a + g.lat.reduce((x, y) => x + y, 0), 0);
    const rows = [...this.groups.values()].map((g) => {
      const lat = [...g.lat].sort((a, b) => a - b);
      const sum = lat.reduce((a, b) => a + b, 0);
      const row = {
        service: g.service, method: g.method, route: g.route, count: g.count,
        rate5xx: g.count ? g.e5xx / g.count : 0, rate4xx: g.count ? g.e4xx / g.count : 0,
        e5xx: g.e5xx, e4xx: g.e4xx,
        p50: percentile(lat, 50), p95: percentile(lat, 95), p99: percentile(lat, 99),
        max: lat.length ? lat[lat.length - 1] : 0,
        timeShare: totalTime ? sum / totalTime : 0,
      };
      row.flags = evaluate(row, budgets);
      return row;
    });
    rows.sort((a, b) => b.p95 - a.p95 || b.count - a.count);
    return rows;
  }

  eventsList() {
    return [...this.events.entries()].map(([service, e]) => ({
      service, deadline: e.deadline, timeout: e.timeout, panic: e.panic,
      samples: [...e.samples.values()],
    }));
  }
}

export function budgetFor(budgets, row) {
  const b = budgets || {};
  const def = { ...DEFAULT_BUDGET, ...(b.default || {}) };
  const routes = b.routes || {};
  const ov = routes[`${row.service} ${row.method} ${row.route}`] || routes[`${row.method} ${row.route}`] || routes[row.route] || {};
  return { ...def, ...ov };
}

export function evaluate(row, budgets) {
  const b = budgetFor(budgets, row);
  const flags = [];
  if (row.p95 > b.p95Ms) flags.push('P95');
  if (row.p99 > b.p99Ms) flags.push('P99');
  if (row.max > b.maxMs) flags.push('MAX');
  if (row.rate5xx > b.errorRate5xx) flags.push('5XX');
  return flags;
}

// ---------- rendering ----------
const f1 = (n) => (n >= 100 ? n.toFixed(0) : n.toFixed(1));
const pct = (n) => (n * 100).toFixed(n > 0 && n < 0.001 ? 2 : 1) + '%';

function tableCells(rows) {
  return rows.map((r) => [
    r.service, r.method, r.route, String(r.count), pct(r.rate5xx), pct(r.rate4xx),
    f1(r.p50), f1(r.p95), f1(r.p99), f1(r.max), pct(r.timeShare), r.flags.join(','),
  ]);
}
const HEAD = ['service', 'method', 'route', 'n', '5xx', '4xx', 'p50', 'p95', 'p99', 'max', 'time%', 'flags'];

export function renderTable(rows, top) {
  const shown = top ? rows.slice(0, top) : rows;
  const cells = [HEAD, ...tableCells(shown)];
  const w = HEAD.map((_, i) => Math.max(...cells.map((c) => c[i].length)));
  const num = new Set([3, 4, 5, 6, 7, 8, 9, 10]);
  return cells.map((c) => c.map((v, i) => (num.has(i) ? v.padStart(w[i]) : v.padEnd(w[i]))).join('  ').trimEnd()).join('\n');
}

export function renderMarkdown(rows, top) {
  const shown = top ? rows.slice(0, top) : rows;
  const lines = ['| ' + HEAD.join(' | ') + ' |', '|' + HEAD.map(() => '---').join('|') + '|'];
  for (const c of tableCells(shown)) lines.push('| ' + c.map((v, i) => (i === 2 ? '`' + v + '`' : v)).join(' | ') + ' |');
  return lines.join('\n');
}

function renderEvents(events, md) {
  const out = [];
  for (const e of events) {
    out.push(md
      ? `- **${e.service}**: deadline=${e.deadline} timeout=${e.timeout} panic=${e.panic}`
      : `${e.service}: deadline=${e.deadline} timeout=${e.timeout} panic=${e.panic}`);
    for (const s of e.samples) out.push(md ? `  - (${s.kind} x${s.n}) \`${s.sample.replace(/`/g, "'")}\`` : `    [${s.kind} x${s.n}] ${s.sample}`);
  }
  return out.join('\n');
}

// ---------- input ----------
async function readStream(stream, cb) {
  const rl = createInterface({ input: stream, crlfDelay: Infinity });
  for await (const line of rl) cb(line);
}

function sshLogs(host, container, since, cb) {
  return new Promise((resolve, reject) => {
    const cmd = `docker logs --since ${since} ${container} 2>&1`;
    const p = spawn('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', host, cmd], { stdio: ['ignore', 'pipe', 'pipe'] });
    let err = '';
    p.stderr.on('data', (d) => { err += d; });
    const reading = readStream(p.stdout, cb);
    p.on('error', reject);
    p.on('close', async (code) => {
      await reading;
      if (code !== 0) reject(new Error(`ssh ${container} exit ${code}: ${err.trim().split('\n').slice(-2).join(' ')}`));
      else resolve();
    });
  });
}

function parseArgs(argv) {
  const a = { host: 'lborx@192.168.1.21', since: '6h', services: 'all', top: 40, format: 'table', budgets: path.join(HERE, 'budgets.json'), stdin: false, serviceName: 'stdin' };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    const v = () => { if (i + 1 >= argv.length) throw new Error(`missing value for ${k}`); return argv[++i]; };
    if (k === '--host') a.host = v();
    else if (k === '--since') a.since = v();
    else if (k === '--services') a.services = v();
    else if (k === '--top') a.top = Number(v());
    else if (k === '--budgets') a.budgets = v();
    else if (k === '--service-name') a.serviceName = v();
    else if (k === '--stdin') a.stdin = true;
    else if (k === '--json') a.format = 'json';
    else if (k === '--markdown') a.format = 'markdown';
    else if (k === '-h' || k === '--help') a.help = true;
    else throw new Error(`unknown flag ${k}`);
  }
  return a;
}

function loadBudgets(file) {
  try { return JSON.parse(readFileSync(file, 'utf8')); } catch (e) {
    throw new Error(`cannot read budgets ${file}: ${e.message}`);
  }
}

async function main() {
  let a;
  try { a = parseArgs(process.argv.slice(2)); } catch (e) { console.error(e.message); process.exit(2); }
  if (a.help) {
    console.log('node latency-report.mjs [--host H] [--since 6h] [--services all|a,b] [--stdin] [--service-name N] [--budgets F] [--top N] [--json|--markdown]');
    return;
  }
  let budgets;
  try { budgets = loadBudgets(a.budgets); } catch (e) { console.error(e.message); process.exit(2); }
  const agg = new Aggregator(budgets.ignore || DEFAULT_IGNORE);

  if (a.stdin) {
    await readStream(process.stdin, (l) => agg.add(a.serviceName, l));
  } else {
    if (!/^[\w.@-]+$/.test(a.host)) { console.error('bad --host'); process.exit(2); }
    if (!/^\d+[smh]$|^\d+h\d+m$/.test(a.since)) { console.error('bad --since (e.g. 30m, 6h, 24h)'); process.exit(2); }
    const names = a.services === 'all' ? ALL_SERVICES : a.services.split(',').map((s) => s.trim()).filter(Boolean);
    const targets = names.map((n) => {
      const short = n.replace(/^coachify-/, '');
      if (!/^[a-z][a-z0-9-]*$/.test(short)) { console.error(`bad service ${n}`); process.exit(2); }
      return short;
    });
    const results = await Promise.allSettled(targets.map((s) => sshLogs(a.host, `coachify-${s}`, a.since, (l) => agg.add(s, l))));
    const failed = results.map((r, i) => (r.status === 'rejected' ? `${targets[i]}: ${r.reason.message}` : null)).filter(Boolean);
    for (const f of failed) console.error('WARN ' + f);
    if (failed.length === targets.length) { console.error('all sources failed'); process.exit(2); }
  }

  const rows = agg.rows(budgets);
  const events = agg.eventsList();
  const violations = rows.filter((r) => r.flags.length);
  const meta = { source: a.stdin ? 'stdin' : `${a.host} since ${a.since}`, ...agg.stats, routes: rows.length, violations: violations.length };

  if (a.format === 'json') {
    console.log(JSON.stringify({ meta, rows, events }, null, 2));
  } else if (a.format === 'markdown') {
    console.log(`## Latency report (${meta.source})\n`);
    console.log(`${meta.requests} requests, ${meta.routes} routes, ${meta.violations} over budget. Latency in ms.\n`);
    console.log(renderMarkdown(rows, a.top));
    if (events.length) console.log('\n### Timeouts / deadlines / panics\n\n' + renderEvents(events, true));
  } else {
    console.log(`source: ${meta.source}  lines=${meta.lines} requests=${meta.requests} ignored=${meta.ignored} noLatency=${meta.noLatency} routes=${meta.routes} overBudget=${meta.violations}`);
    console.log(renderTable(rows, a.top));
    if (a.top && rows.length > a.top) console.log(`... ${rows.length - a.top} more rows (use --top 0 for all)`);
    if (events.length) console.log('\nTimeout / deadline / panic lines:\n' + renderEvents(events, false));
  }
  process.exit(violations.length ? 1 : 0);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => { console.error(e.message); process.exit(2); });
}
