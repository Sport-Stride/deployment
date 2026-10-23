# Backend performance quality check

Two zero-dependency Node tools in `tools/perf/` find slow or failing endpoints. Full usage: `tools/perf/README.md`.

1. **Passive** - `node tools/perf/latency-report.mjs --since 24h` reads `docker logs` of the `coachify-*-api` containers over ssh, groups requests by service + method + route, and prints p50/p95/p99/max, 4xx/5xx rate and share of total request time, plus `context deadline exceeded` / timeout / panic lines per service.
2. **Active** - `node tools/perf/probe.mjs` logs in with a dedicated test account and times read-only GETs through the Next.js proxy (`/api/proxy/<service>/<path>`).

Budgets (`tools/perf/budgets.json`): p95 800 ms, p99 2000 ms, max 10 s, 5xx rate 1%, with per-route overrides.

Exit code `0` = within budget, `1` = budget exceeded (use it for cron/CI alerts), `2` = tool or setup error.

Suggested routine: run the log report daily from the server cron, run the probe nightly or after each deploy, and run `node tools/perf/selftest.mjs` after editing the tools.
