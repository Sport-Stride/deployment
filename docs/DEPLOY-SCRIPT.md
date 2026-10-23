# deploy-service.sh

Single-service (or full-stack) deploy with preflight, image wait, health gate, post-checks and automatic rollback.
Script: `scripts/deploy-service.sh`. Self-test: `bash scripts/deploy-service.test.sh`.

## Usage

```
scripts/deploy-service.sh <service|all> [<full-sha>|latest-from-versions]
    [--host user@host] [--local] [--dry-run] [--no-smoke] [--wait-image <min>] [--force]
```

- Default host `lborx@192.168.1.21`, project dir `~/production/coachify` (override with `COACHIFY_DIR`).
- From the laptop the script uses your ssh agent (`BatchMode`; `/tmp/ssh-*/agent.*` is auto-discovered if `SSH_AUTH_SOCK` is unset or dead), copies itself to the server and runs there with `--local`. On the server, pass `--local`.
- `latest-from-versions` (default) = use the sha already in `versions.env` (e.g. CI wrote it). `all` only supports this.
- Service names are compose names; `identifier` etc. work as alias for `identifier-api`.
- `--wait-image N`: wait up to N minutes (default 20) for CI to publish the image, retrying every 20 s.
- `--force`: deploy even if the current container is unhealthy.

## Service map

| service | VERSION var in versions.env | container | internal port | health URL (container IP) |
|---|---|---|---|---|
| identifier-api | IDENTIFIER_API_VERSION | coachify-identifier-api | 8080 | /health |
| notification-api | NOTIFICATION_API_VERSION | coachify-notification-api | 8081 | /health |
| content-api | CONTENT_API_VERSION | coachify-content-api | 8084 | /health |
| workout-api | WORKOUT_API_VERSION | coachify-workout-api | 8087 | /health |
| tracker-api | TRACKER_API_VERSION | coachify-tracker-api | 8088 | /health |
| statistics-api | STATISTICS_API_VERSION | coachify-statistics-api | 8089 | /health |
| payments-api | PAYMENTS_API_VERSION | coachify-payments-api | 8086 | /health |
| account-api | ACCOUNT_API_VERSION | coachify-account-api | 8082 | /health |
| invitation-api | INVITATION_API_VERSION | coachify-invitation-api | 8085 | /health |
| chat-api | CHAT_API_VERSION | coachify-chat-api | 8083 | /health |
| frontend | FRONTEND_VERSION | coachify-frontend | 3000 | /api/auth/session |

Images: `ghcr.io/sport-stride/coachify-<service>:<sha>`. `all` deploys in the table order (light to heavy, frontend last) and stops at the first failure; only that service is rolled back.

Backend containers define no docker healthcheck, so the gate is: container `running`, no restarts, HTTP 2xx/3xx on `/health` (a 4xx counts as "alive, path unverified" with a warning). Adjust `SVC_HPATH` in the script if a service uses another path.

## Pipeline

1. Preflight: ssh, disk > 5 GB, memory/swap warning, `docker compose config -q`, known service, 40-hex sha, current container healthy (unless `--force`), PID lock `~/production/coachify/.deploy.lock` (stale locks are reclaimed).
2. Image: use the local image if present, else `docker pull` with retries (not found = CI not done; DNS errors also retried). `versions.env` is not touched before this succeeds.
3. Backup `versions.env` to `versions.env.bak-YYYYMMDD<letter>` (next free letter); record previous image id and digest.
4. Set the version var, `docker compose --env-file .env.production --env-file versions.env -f docker-compose.prod.yml up -d --no-deps --pull never <service>`, health gate (90 s), scan logs for `panic|fatal` over the first 60 s.
5. Post-checks: nginx `-t` + reload (all services, upstream IPs change on recreate); frontend also smoke tests `/auth/signin` and `/api/auth/providers` (200, browser User-Agent) on `https://app.coachify.tn` (override `SMOKE_BASE`; skip with `--no-smoke`). If `tools/perf/probe.mjs` exists and node is installed, `--dry-run` of it is run and reported only.
6. Any failure from step 4 on: restore `versions.env` from the backup, recreate with the previous image (retagged from the recorded image id if the tag vanished), re-run the gate.
7. Append a line to `~/production/coachify/deploy.log` (`time user service old new result`) and print a summary.

## Exit codes

| code | meaning |
|---|---|
| 0 | deployed and healthy (or dry-run ok) |
| 2 | preflight or usage error, nothing changed |
| 3 | `IMAGE NOT PUBLISHED - nothing changed` |
| 4 | new version failed, `ROLLED BACK to <sha>`, previous version healthy |
| 5 | rollback failed, manual action needed (backup path is printed) |

## Examples

```bash
# preview, read-only
scripts/deploy-service.sh frontend 4b079ec23c1bf80178799dc4990a51b58800cb73 --dry-run
# deploy, wait up to 30 min for CI to push the image
scripts/deploy-service.sh statistics-api <sha> --wait-image 30
# versions.env already updated, just roll everything in safe order
scripts/deploy-service.sh all latest-from-versions
# on the server
./scripts/deploy-service.sh account-api <sha> --local
```

## Troubleshooting

- `ssh to ... failed`: start/load your agent (`ssh-add -l`); the script needs key auth, no prompts.
- Exit 3: CI has not pushed the tag. Check the workflow run, re-run with a larger `--wait-image`.
- `another deploy is running`: check `cat .deploy.lock`; a dead PID is cleaned automatically, otherwise wait.
- `unhealthy BEFORE deploy`: fix or restart the current container, or use `--force`.
- Exit 4: read the `WARN` line above `ROLLED BACK` (health timeout, panic in logs, smoke failure). Logs: `docker logs coachify-<service>`.
- Exit 5: the previous version is not healthy either. Restore by hand: `cp versions.env.bak-<...> versions.env` then `docker compose --env-file .env.production --env-file versions.env -f docker-compose.prod.yml up -d --no-deps --pull never <service>`.
- Smoke 403: the proxy blocks the default curl UA; the script already sends a browser UA.
- Tunables (env): `HEALTH_TIMEOUT` (90), `SCAN_WINDOW` (60), `POLL` (3), `WAIT_SLEEP` (20), `NGINX_CTR`, `SMOKE_BASE`.

## Replaces the manual steps

| manual | script |
|---|---|
| `sed -i` the version in versions.env | backup + idempotent edit, only after a successful pull |
| `docker pull` (retry on DNS) | retry loop up to `--wait-image` |
| `docker compose up -d --no-deps <svc>` | same, with `--pull never` and health gate |
| `docker exec coachify-nginx-proxy nginx -s reload` | automatic after recreate |
| curl with a browser UA | built-in smoke tests |
| restore the old sed by hand | automatic rollback, exit 4 |
