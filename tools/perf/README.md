# Backend performance quality tools

Node 20+, ES modules, no dependencies. Read-only: nothing here writes to the servers or the database.

| File | Purpose |
|---|---|
| `latency-report.mjs` | Passive: parses Go zap request logs, ranks routes by p95, flags budget breaches |
| `probe.mjs` | Active: times read-only GET endpoints through the public Next.js proxy |
| `budgets.json` | Thresholds for the report (defaults + per-route overrides + ignore list) |
| `endpoints.json` | Endpoint list for the probe |
| `selftest.mjs` | `node tools/perf/selftest.mjs` - parser/aggregator/budget/plan tests |

## latency-report

```sh
# last 24h, all backend containers, via ssh (needs a working ssh agent / key, BatchMode)
node tools/perf/latency-report.mjs --host lborx@192.168.1.21 --since 24h --services all
node tools/perf/latency-report.mjs --services payments-api,account-api --since 6h --markdown
node tools/perf/latency-report.mjs --json > report.json
# from any log stream
ssh host docker logs --since 1h coachify-payments-api 2>&1 | node tools/perf/latency-report.mjs --stdin --service-name payments-api
```

Flags: `--host` (default `lborx@192.168.1.21`), `--since` (`30m`, `6h`, `24h`), `--services all|a,b` (container `coachify-<name>`; names like `payments-api`), `--budgets file`, `--top N` (default 40, 0 = all), `--json`, `--markdown`, `--stdin`, `--service-name`.

Parsed: both `request` (ERROR, from `utils/gin_zap.go`) and `request completed` (INFO, gin) lines, plus account-api style lines (`latency` as a duration string, no `route`; ids in the path are collapsed to `:id`). Rows are grouped by service + method + `route` template. `/health`, `/metrics`, `/status` are ignored (see `budgets.json` `ignore`). Lines without `latency_ms` count towards request/error totals but not percentiles.

Columns: `n` requests, `5xx` / `4xx` rate, `p50/p95/p99/max` in ms (nearest-rank), `time%` share of total request time (high share + moderate p95 = the routes that load the server most), `flags` = which budget broke (`P95`, `P99`, `MAX`, `5XX`).

Below the table: per-service counts of `context deadline exceeded`, timeouts and panics with up to 5 de-duplicated, scrubbed samples (emails, bearer tokens, URL query strings removed).

Exit codes: `0` within budget, `1` at least one route over budget, `2` usage/ssh/budget file error.

### Budgets

`budgets.json`: `default` `{p95Ms, p99Ms, maxMs, errorRate5xx}`, `ignore` route prefixes, `routes` overrides keyed `"METHOD /route"` or `"service METHOD /route"`. Defaults: p95 800 ms, p99 2000 ms, max 10000 ms, 5xx 1%.

### Cron on the server

```cron
# /etc/cron.d/coachify-perf  (alerts by mail through cron's MAILTO when exit != 0 output is produced)
MAILTO=ops@example.com
0 7 * * * lborx cd /opt/coachify/deployment-finale && node tools/perf/latency-report.mjs --host localhost --since 24h --markdown || true
```

On the server itself use `--host` of a local ssh target, or pipe `docker logs` with `--stdin`. To alert only on breach, replace `|| true` with a notify step: `... --markdown > /tmp/perf.md || mail -s "perf budget exceeded" ops@example.com < /tmp/perf.md`.

### Nightly GitHub Action (example only, not added)

```yaml
name: perf-quality
on:
  schedule: [{ cron: '0 3 * * *' }]
  workflow_dispatch:
jobs:
  probe:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 20 }
      - run: node tools/perf/selftest.mjs
      - run: node tools/perf/probe.mjs --repeat-slowest
        env:
          PERF_BASE_URL: https://app.coachify.tn
          PERF_EMAIL: ${{ secrets.PERF_EMAIL }}
          PERF_PASSWORD: ${{ secrets.PERF_PASSWORD }}
          PERF_CLIENT_ID: ${{ secrets.PERF_CLIENT_ID }}
          PERF_COACH_ID: ${{ secrets.PERF_COACH_ID }}
```

A failing step (exit 1) fails the job, which notifies repository watchers. The log report needs ssh access, so run it from the server cron instead.

## probe

```sh
export PERF_EMAIL=... PERF_PASSWORD=...        # dedicated test account, never commit
export PERF_CLIENT_ID=... PERF_COACH_ID=...    # a client linked to that coach
node tools/perf/probe.mjs --dry-run            # list the plan, send nothing
node tools/perf/probe.mjs                      # 15 runs per endpoint, concurrency 3, 1 warm-up discarded
node tools/perf/probe.mjs --n 30 --service payment --repeat-slowest
```

Flags: `--n`, `--concurrency`, `--config`, `--filter text`, `--service name`, `--repeat-slowest` (reruns the 5 slowest with N=50 and uses those numbers), `--json`, `--dry-run`. Env: `PERF_BASE_URL` (default `https://app.coachify.tn`).

How auth works: the probe logs in with `POST {base}/api/proxy/account/user/login` (same endpoint the Next.js credentials provider calls on account-api `/user/login`), takes `user.token`, then calls `GET {base}/api/proxy/<service>/<path>` with `Authorization: Bearer <token>`. Services are the proxy keys: `account workout chat invitation statistics tracker content payment`. Credentials and tokens are never printed.

Exit codes: `0` ok, `1` an endpoint exceeded its p95 budget (default 800 ms, or `budgetP95Ms`) or returned a status outside `expectStatus`, `2` setup error (missing env, login failed, bad config). Endpoints needing `{clientId}`/`{coachId}` are skipped when the env var is unset.

### Add an endpoint

Append to `endpoints.json`:

```json
{ "name": "statistics: notes", "method": "GET", "service": "statistics", "path": "/notes?client_id={clientId}", "expectStatus": 200, "budgetP95Ms": 800, "needs": ["clientId"] }
```

`method` must be `GET` (the probe refuses anything else). `expectStatus` may be a number or an array. `enabled: false` keeps an entry documented but unused (e.g. identifier, which is not behind the proxy). Check that the route exists in the service router and is idempotent before adding it.

## Reading results

- Start with `flags`. `P95`/`P99` slow tail; `MAX` single outlier; `5XX` error rate.
- Compare probe and log numbers: slow in the probe but fast in logs means the delay is outside the Go service (Next.js proxy, nginx, network). Slow in both means the service or its downstream (Mongo, another service).
- A route with `5XX` and a `context deadline exceeded` sample in the events section is a downstream timeout (the sample names the caller and callee).
- High `time%` with healthy p95 means volume: cache or batch rather than optimise one call.
- Cold single samples (n small) are noisy: re-run the window or use `--repeat-slowest` before acting.
