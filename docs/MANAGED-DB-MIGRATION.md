# Migration to a managed MongoDB (Atlas)

Status: runbook. Tooling: `scripts/mongodb/preflight-managed.sh`, `migrate-to-managed.sh`, `verify-migration.sh`.

## 1. Decision summary

Today production runs ONE `mongo:6.0` container (`coachify-mongodb`, host `mongodb:27017`, 1 GB memory limit, bound to 127.0.0.1, volume `mongo_data`) on a 3 GB home server shared with 11 services, RabbitMQ, nginx, monitoring and other containers.

Problems:
- Single instance, no replica set: any crash, disk fault or `docker volume` mishap means downtime, and possibly data loss.
- No automated backups or point-in-time restore. Only ad-hoc dumps.
- RAM pressure: Mongo (WiredTiger cache) competes with the services on a 3 GB host.
- No monitoring or alerting on the DB itself, no failover, no rolling upgrades.

Data size is small (measured read-only on the server, 2026-10-23): about 7 MB of data and 5 MB of indexes in total, about 6,800 documents across 7 databases (`COACHIFY`, `CONTENT`, `identifier`, `statistics_read`, `statistics_write`, `users`, `workout-management`). The copy takes about a minute. The migration risk is operational (connection strings, pools, network), not data volume.

### Options

| | A. MongoDB Atlas (managed) | B. Self-hosted 3-node replica set |
|---|---|---|
| Ops effort | Lowest. Backups, failover, upgrades, monitoring included. | Highest. You run 3 nodes, keyfile auth, backups, upgrades. |
| Resilience | 3-node replica set by default (dedicated tiers). | Only real HA if the 3 nodes are on 3 separate machines. 3 containers on this one host are not HA and use more RAM. |
| Cost | Recurring fee (see bands below). | 2 extra small VPS/VMs, plus your time. |
| Latency to app | WAN round trip (25-60 ms from Tunisia to EU). | LAN/same host, or similar if remote. |
| Backups / PITR | Built in (continuous backup on dedicated tiers). | Build yourself (mongodump cron, off-site copy, oplog for PITR). |

Recommendation: Atlas, dedicated M10 (or the smallest tier that gives continuous backup), region Paris (AWS eu-west-3) or Frankfurt, else Milan. Flex (shared, pay-as-you-go, capped) is acceptable for a first step and costs less, but check: a connection cap of about 500, a throughput cap, no continuous/point-in-time backup (daily snapshots only), and the tier's server version. Do not use the free M0 tier for production.

Rough cost bands (indicative only, not quotes; CONFIRM CURRENT PRICING on the Atlas pricing page and the cluster creation screen before deciding):
- Flex: roughly a few USD to about 30 USD/month, usage-capped.
- Dedicated M10: roughly 55 to 80 USD/month depending on cloud and region, plus backup and data-transfer charges.
- Self-hosted replica set: 2 extra small VMs, roughly 10 to 30 USD/month each, plus operations time.

Region and latency: the app server is in Tunisia. Paris, Frankfurt and Milan typically give about 25-60 ms RTT; measure with `preflight-managed.sh` (p50/p95 of 20 pings). Every query now pays this RTT. Hot paths that do N sequential queries per request will feel it: the project rule "one aggregation pipeline, not N round-trips" matters more after this migration. If p50 is above 80 ms the preflight warns, above 250 ms it fails.

## 2. Facts about the current setup (verified in the repos)

- Connection strings are read from three env vars in `.env.production` (server path `~/production/coachify/.env.production`): `MONGODB_URI`, `MONGO_URI`, `MONGO_URL`. Which service reads which:
  - `MONGODB_URI`: account, chat, identifier.
  - `MONGO_URL`: content-management, invitation, tracker, workout-management (plus the content/invitation/tracker/workout "local" defaults).
  - `MONGO_URI`: payments, statistics.
  - All of them are loaded through compose `env_file: .env.production`. **All three variables must be changed together, to the managed cluster, in one edit.** Changing only one leaves part of the platform writing to the old database (silent data split).
- Database names: services take them from config/env (`DATABASE_NAME`, statistics `statistics_read` / `statistics_write` / `users`). On the server the databases that exist today are `COACHIFY`, `CONTENT`, `identifier`, `statistics_read`, `statistics_write`, `users`, `workout-management` (plus system DBs, which are not migrated). The scripts discover the list from the local instance; override with `--dbs`.
- Names are case-sensitive: the managed cluster must keep the exact same names (the scripts do).
- Local version is 6.0.28. Atlas will offer a newer major (7.0 or 8.0). The Go driver in all services is `go.mongodb.org/mongo-driver` v1.17.x, which supports MongoDB up to 8.0. Choose 7.0 for the least surprise, or 8.0 after a rehearsal; the preflight only fails if the managed version is OLDER than local.
- The local app user (`MONGO_APP_USER`) has `readWriteAnyDatabase`.
- Pool settings in code (per process, per client):
  - workout-management: `MAX_POOL_SIZE` / `MIN_POOL_SIZE` env (defaults 300 / 50), `CONN_TIMEOUT`, `QUERY_TIMEOUT`.
  - tracker: hardcoded `SetMaxPoolSize(200)`, `SetMinPoolSize(10)` (`config/config.go`).
  - payments: 50 / 5 for the write client, 100 / 5 for the read client (`config/initializeDB.go`).
  - statistics, account, chat, identifier, content, invitation: driver defaults (max 100, min 0). statistics opens a write and a read client.
- Services that write to Mongo (stopped for the final copy): `tracker-api`, `statistics-api`, `identifier-api`, `account-api`, `chat-api`, `content-api`, `invitation-api`, `payments-api`, `workout-api`. `notification-api` and `frontend` do not use Mongo directly, but they share `env_file` and are recreated at the switch. `landing` has no `env_file`.
- Async path: tracker publishes to RabbitMQ (CloudAMQP) and statistics consumes. Messages queued while statistics is stopped are kept by the broker; they are processed after the restart, against the new DB.

## 3. Atlas checklist (what you do in the Atlas console)

1. Create the project and cluster.
   - Tier: dedicated M10 (recommended) or Flex; cloud provider AWS or GCP; region Paris / Frankfurt / Milan.
   - MongoDB version: 7.0 (or 8.0, see above).
   - Backup: enable **Cloud Backup** and, where the tier offers it, **Continuous Cloud Backup (point-in-time restore)**. Set snapshot retention (7 days minimum).
   - Auto-scaling: leave storage auto-scale on; compute auto-scale off at first.
2. Database access.
   - Create user `coachifyApp` with password auth (long random password, URL-encode special characters in the URI).
   - Least privilege: custom role (or one `readWrite` entry per database) on exactly: `COACHIFY`, `CONTENT`, `identifier`, `statistics_read`, `statistics_write`, `users`, `workout-management`. Avoid `atlasAdmin` and `readWriteAnyDatabase` for the app user.
   - `readWrite` already includes create/drop collection, index builds, and `listIndexes`; the migration (restore with `--drop`) works with that same user. If you prefer, create a short-lived migration user with `readWriteAnyDatabase` and delete it at T+1d.
3. Network access.
   - IP access list: add the server's PUBLIC IPv4 only (check with `curl -s https://api.ipify.org` on the server). If the ISP address is dynamic, plan for it: set an alert, or use a stable egress (VPN/VPS with fixed IP) before cutover. Never leave `0.0.0.0/0`.
   - TLS is always on for Atlas. Use the `mongodb+srv://` string.
4. Connection string (put it ONLY in the server's env file, never in chat, tickets or shell history): copy the SRV string from "Connect > Drivers > Go". Recommended options appended to the URI: `retryWrites=true&w=majority`. Optional: `maxPoolSize=` / `minPoolSize=` / `maxIdleTimeMS=` only for services without explicit pool code (see section 7).
5. Alerts (Project > Alerts): connections above 80% of the tier limit, replication lag, disk above 80%, CPU above 80%, "host down", failed backup, and "cluster not reachable". Send them to an email you read.
6. Provide the URI to the scripts through the server only:

Create the file on the server with an editor: `nano ~/production/coachify/.managed-db.env` containing the single line `NEW_URI=mongodb+srv://...`, then `chmod 600 ~/production/coachify/.managed-db.env`. Do not use `echo`/`printf` with the URI (shell history). It must NOT go into `.env.production` until the switch (compose would hand it to every container). The scripts accept `NEW_URI` from the environment as well; they never print it and mask credentials in all output.

## 4. Tooling

All scripts run ON THE SERVER from `~/production/coachify` (clone/copy `scripts/mongodb/` there). Prerequisites: docker, the `coachify-mongodb` container running, `LOCAL_MONGO_ROOT_PASSWORD` in `.env.production` or `.env`, and `NEW_URI` as above. They use a throwaway `mongo:7` container (memory limit 256-384 MB, removed after use) on the same Docker network. Credentials reach the tools through a mode-0700 temp directory with 0600 files mounted read-only; it is deleted at exit. Nothing secret is on a command line.

| Script | Purpose |
|---|---|
| `preflight-managed.sh` | DNS/TLS/connect, auth, version >= local, latency p50/p95 (20 pings), readWrite on every DB, what already exists on the target. Prints PASS/FAIL per check. |
| `migrate-to-managed.sh --dry-run` | Read-only: preflight, local sizes, time estimate, the plan. |
| `migrate-to-managed.sh --rehearsal` | Copy all DBs with the same names while the app runs. Repeatable (`--drop` per collection), then `verify-migration.sh --allow-drift`. Prints measured duration. |
| `migrate-to-managed.sh --final` | Backup, stop writers, dump|restore, strict verify, print the switch steps. Restarts the writers on any failure. Does not edit the env file. |
| `verify-migration.sh` | Per collection: presence, type, capped options, `countDocuments`, index names and definitions, sampled (1000) content checksum. TTL collections: count/sample diffs are WARN. Non-zero exit on mismatch. |

Limits to know:
- The copy is `mongodump --archive --gzip | mongorestore --archive --gzip --nsInclude 'db.*' --drop`, per database. No replica set means no `--oplog`: the rehearsal copy is NOT a point-in-time snapshot while the app is writing. Only `--final` (writers stopped) gives a consistent copy.
- `--drop` replaces collections that exist locally. It does not remove collections that exist only on the target; `verify` reports those as FAIL ("MANAGED only"). Drop them manually on the target if they are stale rehearsal leftovers.
- Users and roles are not migrated (the Atlas user is created in the console).

## 5. Runbook and timeline

### T-7d: prepare and rehearse
1. Create the Atlas cluster and user (section 3). Put `NEW_URI` in `.managed-db.env`.
2. `./scripts/mongodb/preflight-managed.sh` must end with `PREFLIGHT: PASS`. Record latency p50/p95.
3. `./scripts/mongodb/migrate-to-managed.sh --dry-run` and read the estimate.
4. `./scripts/mongodb/migrate-to-managed.sh --rehearsal` (the app keeps running). Expect `VERIFY: PASS` with possible WARN lines for documents written during the copy. Note the duration; repeat as often as you like.
5. Point a staging/local copy of one service at the managed cluster (Mongo URI only) and run its health check, to prove the SRV URI and pool settings work with the Go driver. This is optional but cheap.
6. Review indexes (section 7) and decide pool changes; ship any code change BEFORE the cutover, in its own deploy.
7. Prepare the maintenance page (section 6) and announce the window (quiet hour, estimate: copy + verify + about 10 minutes).

### T-1d
- Re-run preflight and one rehearsal; confirm `VERIFY: PASS`.
- Confirm the server's public IP is in the Atlas access list. Confirm Atlas backup is enabled.
- Make sure `versions.env` matches what is running (the recreate uses `--pull never`).

### T-0: cutover (quiet hour)
1. Optional but recommended: enable the nginx maintenance page (section 6).
2. `./scripts/mongodb/migrate-to-managed.sh --final`. It will:
   1. take a backup of the local data (`~/backups/mongodb/pre-managed-<timestamp>/<db>.archive.gz`, mode 600);
   2. stop the writers: `tracker-api statistics-api identifier-api account-api chat-api content-api invitation-api payments-api workout-api`;
   3. dump | restore with `--drop`;
   4. run `verify-migration.sh` in strict mode (any count, index or sample mismatch fails);
   5. print the switch steps and leave the writers stopped.
   If anything fails, the script restarts the writers on the LOCAL database and exits non-zero. Nothing has changed for users except the pause.
3. Switch (the script prints these; exact commands):
   ```
   cd ~/production/coachify
   cp -p .env.production .env.production.pre-managed-<timestamp>
   # edit: MONGODB_URI, MONGO_URI, MONGO_URL -> managed URI (ALL THREE, same edit)
   grep -cE '^(MONGODB_URI|MONGO_URI|MONGO_URL)=mongodb\+srv://' .env.production    # must print 3
   docker compose --env-file .env.production --env-file versions.env -f docker-compose.prod.yml \
     up -d --no-deps --pull never identifier-api notification-api content-api workout-api tracker-api \
     statistics-api payments-api account-api invitation-api chat-api frontend
   ```
   Alternative with health gates and auto-rollback of images: `scripts/deploy-service.sh all --local` (note: it deploys the image set from `versions.env`).
   Recreate ALL services in the same command. `env_file` is only read when a container is created; a plain `restart` does not pick up the new values.
4. Health gates (all must pass before you disable maintenance mode):
   - `docker ps --format '{{.Names}} {{.Status}}' | grep coachify`: all Up/healthy after about 60 s.
   - Service logs show a successful Mongo init and no auth/server-selection errors: `docker logs --since 3m coachify-account-api 2>&1 | grep -iE 'mongo|error' | head`.
   - Smoke test through the public URL: login, open a workout, a statistics page, a chat message, create+delete a test record.
   - Atlas UI: connections count is sane (see pool budget), no auth failures.
5. Disable the maintenance page. Announce done.

### T+1d: validate
- Atlas metrics: connections, ops/sec, slow queries (Performance Advisor), p95 latency of the key endpoints (Grafana/Loki if used).
- Run `./scripts/mongodb/verify-migration.sh --allow-drift` ONLY to compare against the frozen local copy; counts will differ for tables that received writes since cutover (expected).
- Take a manual Atlas snapshot and test a restore into a scratch cluster once.
- Delete any temporary migration user. Rotate the app DB user password if it has been seen anywhere outside the server (and see `docs/SECRET-ROTATION.md`).

### T+7d: decommission
- Take a last local `mongodump` archive, store it off-server.
- `docker compose ... stop mongodb mongo-express` (both are in the `local-db` profile), then after a further quiet week remove the containers and the `mongo_data` volume. Remove `LOCAL_MONGO_ROOT_PASSWORD`, `MONGO_APP_*`, `LOCAL_MONGO_EXPRESS_PASSWORD` from the env files and `COMPOSE_PROFILES=local-db` from `.env` if present.
- Also from now on mongo-express must not run: it is a web admin UI with the root credentials of the local DB. Do not point it at Atlas.

## 6. Maintenance page (suggestion only: nothing in `nginx/` was changed)

`nginx/conf.d/default.conf` has no maintenance toggle today. A minimal approach (apply and test in advance, not during the window): create `nginx/conf.d/maintenance.inc` on the server containing

```
# enabled by copying maintenance.inc.on over maintenance.inc, disabled by emptying it
location /api/ { return 503; }
error_page 503 @maintenance;
location @maintenance {
    default_type application/json;
    return 503 '{"error":"maintenance in progress, back in a few minutes"}';
}
```
include it in the `server` block with `include /etc/nginx/conf.d/maintenance.inc;`, keep the file empty normally, and toggle with `docker exec coachify-nginx-proxy nginx -s reload`. The frontend itself stays up; only API calls get a clean 503 instead of 502s while writers are stopped. Verify the `location` precedence against your existing `/api/proxy/` and `/api/auth/` blocks before using it (those block names are in `default.conf`). If this feels risky, skip it: the writers are down for only a couple of minutes.

## 7. Post-migration tuning

Connection budget: Atlas limits connections per tier (shared/Flex about 500, M10 about 1,500; confirm on the pricing/limits page). Sum of worst-case pools today: workout up to 300 (default `MAX_POOL_SIZE`), tracker 200, payments 150 (50 + 100), statistics up to 200 (two clients, driver default 100 each), plus 5 more services at up to 100. Minimum (warm) connections: workout 50, tracker 10, payments 10. Each connection costs RAM on the Atlas side. Recommended starting point:
- workout: set `MAX_POOL_SIZE=50`, `MIN_POOL_SIZE=5` in `.env.production` (env-configurable today, no code change).
- tracker: lower `SetMaxPoolSize(200)` to 50 and `SetMinPoolSize(10)` to 5 in `coachify-tracker-api/config/config.go` (hardcoded: needs a code change and deploy).
- payments: keep 50/5 and 100/5, or halve; statistics, account, chat, identifier, content, invitation: add `maxPoolSize=30&minPoolSize=0` to the URI query for services that otherwise use driver defaults (this applies to every service reading that variable, so check each of the three variables' consumers listed in section 2).
- Keep `maxIdleTimeMS` around 60000 so idle connections are recycled.
- Watch the "Connections" chart in Atlas for a week and trim.

Other tasks:
- Index review: compare Atlas Performance Advisor suggestions with `repositories/indexes.go` of each service; indexes are created by the services at startup, and the restore also recreates all indexes. `verify-migration.sh` confirms they match. After cutover, drop nothing until a week of traffic has been observed.
- Timeouts: round trips are now tens of ms. Make sure per-call context deadlines (currently 10 s) and `ServerSelectionTimeout` (payments: 5 s) are still adequate; a failover on Atlas takes about 10-30 s, during which `retryWrites=true` helps.
- Alerts (section 3), backups verified, user password rotation, remove the temporary migration user.
- Update `docs/ARCHITECTURE.md` (it still says MongoDB runs in a separate compose file) and the `.env.production.example` comments.

## 8. Rollback plan

Rollback is possible because the local `coachify-mongodb` container and its volume are never modified by the migration and stay running (idle, unwritten) until T+7d. The final copy only reads from it.

- Before the switch (verification failed, preflight changed, anything odd): the script restarts the writers on the local DB automatically. If it could not, run `docker compose --env-file .env.production --env-file versions.env -f docker-compose.prod.yml start tracker-api statistics-api identifier-api account-api chat-api content-api invitation-api payments-api workout-api`.
- After the switch, within the first hours: `cp -p .env.production.pre-managed-<timestamp> .env.production`, then recreate ALL services with the same `up -d --no-deps --pull never ...` command. Users lose nothing that was written before the cutover; anything written to Atlas since the switch is NOT on the local DB.
- Late rollback (hours to days): first copy back what changed on Atlas since the cutover, then switch the env back. Stop the writers, then for each database run `mongodump` from Atlas and `mongorestore --nsInclude 'db.*' --maintainInsertionOrder` into the local DB (same throwaway-container technique, URIs from a 0600 temp file). Without `--drop`, `mongorestore` skips documents whose `_id` already exists, so updated documents are NOT overwritten. Use `--drop` only if the managed cluster is now the source of truth for that database, which is the normal case after a late rollback (the local copy is older). Rehearse this once before T-0 if the data matters.
- Keep the pre-cutover backup (`~/backups/mongodb/pre-managed-*`) off-server as well.

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Only 1 or 2 of the 3 env vars changed | Split-brain data across old and new DB | Change all three in one edit; the `grep -c ... = 3` check; recreate all services together |
| Server public IP changes (dynamic ISP) | All services lose the DB | Static IP/egress, alert on connection failures, keep the access-list entry current |
| Latency 25-60 ms per query | Slower endpoints, N+1 patterns hurt | Measure in preflight; fix hot N-query paths with one aggregation; pick the nearest region |
| Connection limit exceeded | Auth/ServerSelection errors under load | Lower pool sizes (section 7), watch the Atlas connections chart, use M10 if on Flex |
| Writes lost during the copy | Missing data after switch | Writers stopped for `--final`; backup first; strict verify (counts, indexes, sample checksums) |
| Indexes/TTL differ on the target | Slow queries or data never expiring | `verify` compares names, definitions, `expireAfterSeconds`; restore recreates indexes |
| New major version behaviour | Unexpected query/driver differences | Rehearse against the same version; Go driver 1.17.x supports up to 8.0; choose 7.0 if cautious |
| Credential exposure | DB compromise | URI only in the server's env files (0600); scripts mask output; rotate after cutover; never paste into chat or shell history |
| Atlas outage / maintenance window | App down | Dedicated tier replica set; set the maintenance window to a quiet hour; retryWrites; alerts |
| Rollback after writes on Atlas | Data divergence | Rollback within hours, or export-and-import procedure (section 8) |
| Server RAM/disk during the copy | OOM, slow services | The tools container is limited to 256-384 MB; run in a quiet hour; data is only ~12 MB |
| Cost surprise | Budget | Confirm current pricing; set a billing alert/budget in Atlas |

## 10. What was and was not verified (when this tooling was written)

Verified: `bash -n` on all scripts, argument parsing, URI masking, URL-encoding and `strip_db_path`, generated JavaScript parses (`node --check`), estimate arithmetic, local data sizes via a read-only `db.stats()` on the server. NOT executed against a real Atlas cluster and no dump/restore was run: the first real execution is the T-7d preflight/dry-run/rehearsal, which is what the rehearsal is for. Review the first `verify` output carefully.
