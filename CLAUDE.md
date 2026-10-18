# Coachify Deployment (deployment-finale)

Deployment orchestration hub for the Coachify platform. Service repos publish images to GHCR and send a `repository_dispatch` (`service-built`); the GitHub Actions workflow updates `versions.env`, SSHes to the VPS as `deploy`, and runs `scripts/deploy.sh SERVICE`. Also holds nginx config and the Prometheus/Grafana/AlertManager monitoring stack. Manual deploys use `workflow_dispatch`.

## Stack
GitHub Actions (`appleboy/ssh-action`), Docker Compose, GHCR, nginx, Let's Encrypt, Prometheus, Grafana, AlertManager, bash.

## Layout
`.github/workflows/deploy-to-vps.yml` · `docker-compose.prod.yml` · `docker-compose.monitoring.yml` · `versions.env` (SHA per service, auto-updated) · `nginx/` · `monitoring/` · `scripts/{deploy,rollback,health-check}.sh` · `.env.production` (not in repo).

## Rules
- Never change the dispatch type `service-built`: every service repo depends on it.
- Never change the `versions.env` format (`ACCOUNT_API_VERSION=sha`): compose image substitution `${..._VERSION:-latest}` and the workflow's auto-update depend on it.
- VPS path `/home/deploy/production/coachify` is hard-coded in the workflow, rollback and cron. Change all together.
- Reload nginx with `nginx -s reload`, never `systemctl restart nginx` (drops connections).
- After a failed deploy, `versions.env` may hold the new SHA while the old container still runs: check `docker ps` on the VPS.
- The VPS must be logged in to GHCR (`docker login ghcr.io`) to avoid pull rate limits.
- Keep nginx `zone=auth` at `10r/s burst=30`; it is a circuit breaker, not an abuse signal. The real fix for the `/api/auth/session` 503 storm is the `pendingTokenRefresh` guard in `coachify-client` AxiosProvider; preserve it.
- Watch certbot renewal cron; silent failure expires certs and breaks all HTTPS.
- Secrets live only in GitHub Actions secrets (`DISPATCH_TOKEN`, `VPS_HOST`, `VPS_USERNAME`, `VPS_SSH_KEY`) and `.env.production`. Never commit them.

## Commands
Validate nginx: `nginx -t`. Manual deploy: trigger `workflow_dispatch` on deploy-to-vps.yml. On the VPS: `bash scripts/deploy.sh <service>`, `bash scripts/rollback.sh`, `docker ps`.

Full detail: docs/ARCHITECTURE.md (read only the section needed).
