# Coachify Deployment Repository - CLAUDE.md

## Developer Notes

### Things that have caused bugs before
- **`versions.env` out of sync** — If a deploy fails mid-way, `versions.env` may have the new SHA but the old container is still running. Always check `docker ps` on the VPS after a failed deploy.
- **Nginx config reload vs restart** — Use `nginx -s reload` (graceful) not `systemctl restart nginx` (drops connections). The deploy script handles this correctly — don't change it.
- **Docker image pull rate limits** — GHCR has rate limits for unauthenticated pulls. The VPS must be authenticated to GHCR via `docker login ghcr.io`.
- **SSL certificate renewal** — Let's Encrypt certs auto-renew via certbot cron. If the cron job breaks silently, certs expire and all HTTPS traffic fails.

### How to think about changes here
- The deploy workflow is triggered automatically by `repository_dispatch` events from service repos. Manual deploys use `workflow_dispatch`.
- Each service is independently deployable — updating one service doesn't redeploy others.
- The monitoring stack (Prometheus + Grafana + AlertManager) is deployed alongside services but updated separately.

## 1. WHAT THIS REPOSITORY DOES

### Primary Responsibility
This repository is the **deployment orchestration hub** for the Coachify multi-microservice platform. It detects when individual services (built in separate GitHub repositories) publish Docker images to the GitHub Container Registry (GHCR), automatically orchestrates their deployment to a production VPS via SSH, manages rolling updates across 10+ Go microservices, and provides comprehensive monitoring and observability through a Prometheus/Grafana/AlertManager stack.

### What Data It Owns
- **Service versions** (`versions.env`): Tracks the exact commit SHA of each deployed service image
- **Deployment state**: Backups and deployment logs stored on VPS at `/home/deploy/production/coachify/`
- **Monitoring configuration**: Prometheus scrape configs, alerting rules, Grafana dashboards
- **Infrastructure configuration**: Docker Compose manifests, nginx routing rules, SSL certificates

### What Other Systems It Depends On
- **GitHub workflow triggers**: Responds to `repository_dispatch` events from individual service repos
- **GHCR (GitHub Container Registry)**: Pulls pre-built Docker images tagged with git commit SHAs
- **VPS production server**: Executes deployment scripts via SSH using `appleboy/ssh-action@v1.0.3`
- **Individual service repos** (10 services): Account, Chat, Content, Identifier, Invitation, Notification, Payments, Statistics, Tracker, Workout APIs
- **Frontend repos** (2 apps): Main frontend, landing/vitrine frontend (both Next.js)
- **External services**: MongoDB (database), Redis (caching), Letsencrypt (SSL certificates)

---

## 2. DEPLOYMENT TRIGGER SURFACE

### GitHub Workflow Trigger Mechanism

**File**: `.github/workflows/deploy-to-vps.yml`

#### Trigger Points
```yaml
# 1. Automatic trigger (primary flow)
on:
  repository_dispatch:
    types: [service-built]

# 2. Manual trigger (for emergency deployments)
on:
  workflow_dispatch:
    inputs:
      service:
        description: 'Service to deploy (e.g., account-api) or "all"'
        required: false
        default: 'all'
```

#### How Services Trigger Deployment
Each service repo has its own CI/CD that builds Docker images and calls:
```bash
curl -X POST https://api.github.com/repos/sport-stride/deployment-finale/dispatches \
  -H "Authorization: token $DISPATCH_TOKEN" \
  -d '{
    "event_type": "service-built",
    "client_payload": {
      "service": "account-api",
      "version": "abc123def456..."  # Git commit SHA
    }
  }'
```

#### Workflow Parameters
- **`SERVICE_NAME`**: Single service name (e.g., `account-api`) or special value `all`
- **`SERVICE_VERSION`**: Docker image tag, typically the git commit SHA
- **Authentication**: Uses `DISPATCH_TOKEN` GitHub secret to authenticate dispatch calls

#### What Authentication Is Required
- **GitHub Actions Secrets** (on this repo):
  - `DISPATCH_TOKEN`: GitHub token with repo access (allows services to trigger this workflow)
  - `VPS_HOST`: IP address or hostname of production VPS
  - `VPS_USERNAME`: SSH user account (typically `deploy`)
  - `VPS_SSH_KEY`: SSH private key for `deploy` user on VPS
- **VPS `/home/deploy/.ssh/authorized_keys`**: Public key corresponding to `VPS_SSH_KEY`
- **No API authentication between VPS and services**: All calls are internal Docker network (service-to-service via container DNS)

---

## 3. CODE STRUCTURE

### Repository Layout
```
deployment-finale/
├── .github/
│   └── workflows/
│       └── deploy-to-vps.yml          # Main deployment orchestration (triggers on image builds)
├── docker-compose.prod.yml            # Production stack definition (11 services)
├── docker-compose.monitoring.yml      # Monitoring stack (Prometheus, Grafana, AlertManager)
├── versions.env                       # Service version tracker (auto-updated)
├── .env.production                    # [NOT IN REPO] Production secrets/config
├── nginx/
│   ├── nginx.conf                     # Main nginx config (4096 worker connections)
│   └── conf.d/
│       └── default.conf               # Route definitions for both domains
├── monitoring/
│   ├── prometheus.yml                 # Metrics collection configuration
│   ├── alerts.yml                     # Alert rule definitions (30s evaluation intervals)
│   ├── alertmanager.yml               # Alert routing and deduplication
│   └── grafana/
│       ├── provisioning/
│       │   ├── datasources/
│       │   │   └── prometheus.yml      # Auto-provision Prometheus as data source
│       │   └── dashboards/
│       │       └── dashboard.yml       # Dashboard provisioning config
│       └── dashboards/
│           └── coachify-overview.json  # Pre-built overview dashboard
├── scripts/
│   ├── deploy.sh                      # Core deployment logic (backup, pull, validate, start, health check)
│   ├── health-check.sh                # [EMPTY - stub for future use]
│   └── rollback.sh                    # Service recovery from last stable state
├── init-mongo.js/                     # [DIRECTORY] Possible MongoDB initialization scripts
└── README.md                          # Extensive deployment guide + troubleshooting
```

### Entry Point and Boot Sequence
1. **GitHub Actions triggers** `.github/workflows/deploy-to-vps.yml` (via `repository_dispatch` event)
2. **Workflow extracts** service name and version from `github.event.client_payload`
3. **Workflow updates** `versions.env` and commits to repo (if `repository_dispatch`)
4. **Workflow invokes** SSH tunnel to VPS as `deploy` user
5. **VPS executes** `bash /home/deploy/production/coachify/scripts/deploy.sh SERVICE_NAME`
6. **deploy.sh** orchestrates: backup → pull images → validate → up -d → wait → health checks → log results

### How Services Are Deployed

**Deployment Flow** (from `deploy.sh`):
```bash
1. backup_current_state()
   - Creates point-in-time backup with timestamp
   - Saves running `docker compose ps` output
   - Saves current image list
   - Stores backup name in last-backup.txt for rollback

2. pull_images()
   - Runs: docker compose -f docker-compose.prod.yml pull --quiet
   - Fetches only services with changed image digests from GHCR

3. validate_compose()
   - Runs: docker compose config
   - Ensures YAML is valid before deployment

4. start_services()
   - Runs: docker compose up -d --remove-orphans
   - Starts new/updated containers
   - Removes containers no longer in compose file

5. wait_for_stability()
   - Sleeps 10 seconds to allow services to initialize
   - Prints current docker compose ps output

6. run_health_checks()
   - HTTP checks against /health endpoints
   - Verifies each service is responding
   - Records any failures for monitoring

7. Log summary and return exit code
```

### Service Dependencies and Startup Order
```
nginx-proxy
  ├─ frontend (app.coachify.training)
  │  └─ Multiple internal API calls
  ├─ landing (coachify.training)
  ├─ identifier-api (PORT 8080) [no dependencies]
  ├─ notification-api (PORT 8081) [no dependencies]
  ├─ account-api (PORT 8082)
  │  └─ depends_on: [identifier-api, notification-api]
  ├─ chat-api (PORT 8083)
  │  └─ depends_on: [account-api]
  ├─ content-api (PORT 8084) [no explicit depends_on]
  ├─ invitation-api (PORT 8085) [no explicit depends_on]
  ├─ payments-api (PORT 8086) [no explicit depends_on]
  ├─ workout-api (PORT 8087) [no explicit depends_on]
  ├─ tracker-api (PORT 8088) [no explicit depends_on]
  └─ statistics-api (PORT 8089) [no explicit depends_on]

MongoDB and Redis started in separate docker-compose (not in this repo)
```

### How Routes Are Registered
**Nginx Configuration** (`nginx/conf.d/default.conf`):
- **Upstream blocks** define backend pools:
  ```nginx
  upstream frontend_backend { 
    server frontend:3000; 
  }
  upstream landing_backend { 
    server landing:3001; 
  }
  upstream account_api { 
    server account-api:8082; 
  }
  # ... etc for each service ...
  ```

- **Server blocks** for two domains:
  1. **app.coachify.training** (main app)
     - `/` → frontend (Next.js)
     - `/api/` → frontend's internal proxy route (frontend calls backend APIs)
  
  2. **coachify.training** (vitrine/landing page)
     - `/` → landing
     - `/api/` → frontend (cross-references main app)

- **Reverse proxy patterns**:
  ```nginx
  location /api/ {
    proxy_pass http://frontend_backend;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Host $host;
    proxy_buffering on;
    proxy_buffer_size 16k;
    # Large buffer for NextAuth session cookies
  }
  ```

- **DNS resolution**: Uses Docker's internal resolver (`127.0.0.11:53`)
- **Logging**: JSON-formatted logs sent to volumes (50MB max per file, 5 files rotation)
- **SSL/TLS**: Certificates loaded from `/etc/letsencrypt/` (host-mounted read-only)

### Middleware and Request Chain
```
Browser Request
    ↓
External DNS (coachify.training → VPS IP)
    ↓
Nginx (Port 80/443)
  - SSL/TLS termination (Port 443)
  - HTTP → HTTPS redirect (Port 80)
  - Virtual host routing (app.coachify.training vs coachify.training)
  - Gzip compression enabled
  - Rate limiting (configurable)
  - large proxy buffers for session cookies
    ↓
Backend Service (Frontend or Landing)
  - Next.js Server
    ↓
  - For API calls, Frontend proxies to backend APIs
    - account-api:8082
    - chat-api:8083
    - content-api:8084
    - etc.
    ↓
  [Backend APIs are NOT exposed through nginx directly;
   Frontend does server-side proxy via internal network]
```

---

## 4. MONITORING & OBSERVABILITY LAYER

### Monitoring Architecture
```
Services expose /metrics endpoint
    ↓
Prometheus (Port 9090)
  - Scrapes metrics every 10-15 seconds
  - Stores time-series DB with 30-day retention
  - Evaluates alert rules every 30 seconds
    ↓
  Matches alert expressions
    ↓
AlertManager (Port 9093)
  - Deduplicates and groups alerts
  - Routes by severity and component
  - Sends notifications (Slack webhook, etc.)
    ↓
Slack / Email / PagerDuty
    ↓
[Also]
    ↓
Grafana (Port 3001)
  - Queries Prometheus for visualization
  - Pre-built "coachify-overview" dashboard
  - Auto-provisioned datasources via provisioning files
```

### Prometheus Configuration
**File**: `monitoring/prometheus.yml`

**Global Settings**:
- Scrape interval: 15 seconds
- Evaluation interval: 15 seconds
- External labels: `monitor=coachify-platform`, `environment=production`

**Scrape Targets** (10 microservices):
```yaml
- identifier-api:8080/metrics     (scrape every 10s, label: tier=core)
- notification-api:8081/metrics   (scrape every 10s, label: tier=messaging)
- account-api:8082/metrics        (scrape every 10s, label: tier=core)
- chat-api:8083/metrics           (scrape every 10s, label: tier=messaging)
- content-api:8084/metrics        (scrape every 10s, label: tier=data)
- invitation-api:8085/metrics     (scrape every 10s)
- payments-api:8086/metrics       (scrape every 10s)
- workout-api:8087/metrics        (scrape every 10s)
- tracker-api:8088/metrics        (scrape every 10s)
- statistics-api:8089/metrics     (scrape every 10s)
- prometheus:9090/metrics         (self-monitoring)
```

**Required in each Go service**:
- Export metrics on `:PORT/metrics` endpoint
- Use `github.com/prometheus/client_golang v1.17.0` or later
- Metrics should include:
  - `http_requests_total` (histogram with 5xx status codes)
  - `http_request_duration_seconds` (for latency P95 calculations)
  - Service startup/health indicators

### Alert Rules
**File**: `monitoring/alerts.yml`

**Alert Definitions** (evaluated every 30 seconds):

1. **`ServiceDown`** - CRITICAL
   - Trigger: Any Go API service `up{job=~".*-api"} == 0` for 2+ minutes
   - Severity: Critical
   - Action: Immediate investigation required

2. **`HighErrorRate`** - WARNING
   - Trigger: 5xx error rate > 5% over 5-minute window, sustained 5+ minutes
   - Formula: `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))`
   - Severity: Warning
   - Action: Check service logs, may indicate downstream dependency failure

3. **`HighLatency`** - WARNING
   - Trigger: P95 latency (95th percentile) > 1 second for 5+ minutes
   - Formula: `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (job, le))`
   - Severity: Warning
   - Action: May indicate resource contention or database bottleneck

4. **`HighMemoryUsage`** - WARNING
   - Trigger: Container memory > 85% of limit for 3+ minutes
   - Metric: `container_memory_usage_bytes / container_spec_memory_limit_bytes`
   - Severity: Warning
   - Action: Consider scaling memory allocation or optimizing memory usage

### AlertManager Configuration
**File**: `monitoring/alertmanager.yml`

- Routes alerts based on severity and component
- Deduplicates identical alerts (prevents spam)
- Groups related alerts
- Sends to configured webhook (e.g., Slack)
- Provides silence/inhibition rules for maintenance windows

### Grafana Dashboards
**Pre-built Dashboard**: `monitoring/grafana/dashboards/coachify-overview.json`

- Visualizations for key metrics:
  - Request rates per service
  - Error rates per service
  - P50/P95/P99 latencies
  - Memory and CPU usage per container
  - Service availability status
- Auto-provisioning via `monitoring/grafana/provisioning/dashboards/dashboard.yml`
- Prometheus auto-configured as datasource via `monitoring/grafana/provisioning/datasources/prometheus.yml`

**Grafana Access**:
- URL: `http://vps-ip:3001` (not exposed through nginx)
- Credentials: `admin` / `${GRAFANA_ADMIN_PASSWORD}` (from .env)
- Login disabled (local-only admin account)

---

## 5. DEPLOYMENT CONFIGURATION MANAGEMENT

### Version Tracking (`versions.env`)
Every service image is tracked by commit SHA:
```bash
ACCOUNT_API_VERSION=02312ec19439dc2a3e1ba3e92b1c9e3a87b24061
CHAT_API_VERSION=9b12b041be1e0210cd5657128f935d796ebdb3f1
# ... etc for 10 services ...
FRONTEND_VERSION=e032a0cbcd4a778b7874221e8915d07609d77c81
LANDING_VERSION=f2b11eca04626765755cccbb15b17e5c821c150d
```

**Update Pattern**:
- Initial state: All services point to known good SHAs (tracked in git)
- On service build: Developer/CI pushes image as `ghcr.io/sport-stride/SERVICE:SHA`
- Service repo triggers: `POST /repos/sport-stride/deployment-finale/dispatches` with `version: SHA`
- Deployment workflow: Updates `versions.env` with new SHA, commits, pushes back to repo
- Docker Compose: Uses `${ACCOUNT_API_VERSION}` substitution to pull correct image

### Environment Configuration (`.env.production`)
[Not in repository - stored securely on VPS or CI environment]

**Required Variables**:
```bash
# Database
MONGODB_URI=mongodb://mongo:27017/coachify

# Caching
REDIS_URL=redis://redis:6379

# Secrets (API keys, tokens)
JWT_SECRET=...
OAUTH_CLIENT_ID=...
OAUTH_CLIENT_SECRET=...

# Grafana
GRAFANA_ADMIN_PASSWORD=...
```

**Loaded by**:
- Docker Compose services via `env_file: .env.production`
- Used by all microservices for runtime configuration

### Deployment Metadata
Auto-generated in `versions.env`:
```bash
LAST_DEPLOY_DATE=$(date +%Y-%m-%d)
LAST_DEPLOY_TIME=$(date +%H:%M:%S)
DEPLOYED_BY=github-actions
```

---

## 6. DEPLOYMENT PATTERNS & OPERATIONS

### Blue-Green / Rolling Updates
**Pattern**: Services are updated one at a time via `docker compose pull && up -d`

- Nginx stays up and routes traffic to healthy services
- On `docker compose up -d`:
  - New images downloaded
  - New containers spawned with new images
  - Old containers removed after new ones are healthy
  - No explicit traffic drain - nginx immediately starts routing to new containers
- **Implication**: Ensure services are stateless or have graceful shutdown logic

### Rollback Procedure
**File**: `scripts/rollback.sh`

```bash
1. Read LAST_BACKUP from last-backup.txt (timestamp-based name)
2. docker compose down
3. docker compose up -d  # Uses current versions.env (which hasn't changed yet)
4. Wait 5 seconds for startup
5. Run health checks
6. docker compose ps
```

**Note**: Rollback restarts ALL services, not just the failed one. No selective rollback in current implementation.

**Backup Creation** (in `deploy.sh`):
- Saved as: `backups/backup-{unix-timestamp}.ps`
- Contains: `docker compose ps` output + image list
- Used only for metadata; actual rollback uses compose file state

### Service Memory Allocation
```yaml
account-api:          1.0 CPU limit, 512 MB limit   (largest, core service)
frontend:             1.0 CPU limit, 2 GB limit     (Next.js app)
chat-api:             0.75 CPU limit, 256 MB limit
identifier-api:       0.75 CPU limit, 256 MB limit
website/landing:      0.5 CPU limit, 512 MB limit
notification-api:     0.5 CPU limit, 192 MB limit
content/payment/etc:  0.5-0.75 CPU, 192-256 MB
nginx-proxy:          0.5 CPU limit, 256 MB limit
```

**Total Recommended**: 8 GB RAM (2x current allocation for headroom)

### Health Check Strategy
Located in `deploy.sh` → `run_health_checks()`

**Nginx Health**:
```bash
docker compose exec -T nginx-proxy curl -f http://localhost/health
```

**Service Health** (for each Go API):
```bash
docker compose exec -T {service} curl -f http://localhost:{port}/health
```

**Expected behaviors**:
- HTTP 200 OK = healthy
- Connection refused = container not ready
- HTTP 5xx = service error (may be transient during startup)
- Timeout = unresponsive (deadlock or stuck thread)

**Failure handling**: If health check fails, deployment logs the failure but does NOT automatically rollback. Manual intervention required.

---

## 7. THINGS TO NEVER CHANGE

### Critical Contracts Between Services

#### 1. **Internal Service URLs** (Docker DNS)
Do NOT change these without updating all downstream services:
```bash
identifier-api:8080         # Account, Chat depend on this
notification-api:8081       # Account depends on this
account-api:8082            # Chat, Invitation, Payments depend on this
chat-api:8083               # Frontend depends on this
content-api:8084            # Frontend depends on this
invitation-api:8085         # Account, Frontend depend on this
payments-api:8086           # Account, Frontend depend on this
workout-api:8087            # Frontend depends on this
tracker-api:8088            # Frontend depends on this
statistics-api:8089         # Frontend depends on this
```

**Consequence of changing**:
- Services will fail to connect to dependencies
- Cascading failures up the dependency chain
- 5xx errors for any request that needs that service

#### 2. **Port Mappings** (Internal, not exposed)
- Microservices listen on internal ports: `8080-8089`
- Port mappings are NOT exposed externally through nginx (only frontend does)
- Nginx routing is at path level (`/api/account`, etc), not port level
- **Changing these ports**: Update both docker-compose.prod.yml AND env vars passed to each service

#### 3. **Nginx Route Structure**
**Do NOT change without updating frontend code**:
```nginx
location /api/ {
  proxy_pass http://frontend_backend;  # Frontend does the actual API dispatch
}
```

The frontend (Next.js) has hardcoded internal API URLs:
```
ACCOUNT_API_URL=http://account-api:8082
CHAT_API_BASE_URL=http://chat-api:8083
# etc.
```

Changing path structure requires updating:
1. nginx conf.d/default.conf
2. Frontend environment variables
3. Frontend routing logic

#### 4. **DNS Resolution**
```nginx
resolver 127.0.0.11 valid=10s ipv6=off;  # Docker's internal resolver
```

This is critical for service-to-service communication. Changing this breaks nginx's ability to find Docker services.

#### 5. **Authentication Token Format**
If JWT or OAuth tokens are used:
- **Field names**: Other services parse `Authorization: Bearer {token}` header
- **Claims**: If services extract claims like `sub`, `role`, `email` - these cannot change without updating all services
- **Token endpoint**: If identifier-api is the token authority, its response format is a contract

#### 6. **API Response Field Names**
Any field returned by one service that another service depends on is a contract:
- If account-api returns `{ userId, displayName, email }`, and chat-api or frontend expects these fields
- **Renaming these fields** breaks consumers
- **Adding fields** is fine (optional)
- **Removing fields** breaks consumers

#### 7. **MongoDB Collection Names**
If services share collections or one service reads another's data:
- Collection names and schema structure are contracts
- Individual service repos own which collections they write to
- **Example**: If invitation-api writes to `invitations` collection and account-api reads it to validate invitation codes
- **Changing the collection name** in invitation-api breaks account-api

#### 8. **Error Response Format**
If services call each other and parse error responses:
- HTTP status codes (5xx for server errors, 4xx for client errors)
- Error body format (JSON structure with error message/code)
- **Example**: If account-api expects `{ error: "Invalid identifier", code: "INVALID_ID" }` from identifier-api
- **Changing error format** breaks consumer error handling

### Deployment-Specific Never-Changes

#### 1. **GitHub Repo Dispatch Event Type**
```bash
repository_dispatch:
  types: [service-built]  # DO NOT CHANGE THIS
```

All service repos are configured to trigger only `service-built` events. Changing this event type breaks all upstream builds.

#### 2. **`versions.env` Format**
Current format:
```bash
ACCOUNT_API_VERSION=sha123
```

Used in docker-compose:
```yaml
image: ghcr.io/sport-stride/coachify-account-api:${ACCOUNT_API_VERSION:-latest}
```

**Changing the format** breaks Docker Compose variable substitution.

#### 3. **VPS Directory Path**
```bash
cd /home/deploy/production/coachify
```

GitHub Actions SSH script hard-codes this path. If VPS directory changes, update:
1. GitHub Actions workflow script block
2. Backup/rollback references on VPS
3. Cron jobs or other automation

#### 4. **SSH User and Key**
All VPS deployment depends on:
```
VPS_USERNAME=deploy
VPS_SSH_KEY=private-key-content
```

If VPS or auth method changes, secrets must be updated in GitHub.

#### 5. **Environment Variable Substitution in docker-compose**
```yaml
# This substitution chain is relied upon:
image: ${REGISTRY_PREFIX}/${SERVICE_NAME}:${SERVICE_API_VERSION}
```

The variable names and format must be consistent with auto-update logic in deploy workflow.

---

## 8. GITHUB WORKFLOW DETAILS

### File: `.github/workflows/deploy-to-vps.yml`

#### Trigger Logic
1. **Primary**: `repository_dispatch` event with type `service-built`
   - Sent by individual service repos after building image
   - Includes `client_payload.service` and `client_payload.version`

2. **Secondary**: `workflow_dispatch` (manual trigger)
   - Allows manual deployment of "all" or specific service
   - Used for emergency patches or rollback scenarios

#### Steps

**Step 1: Checkout repository**
```bash
uses: actions/checkout@v4
with:
  token: ${{ secrets.DISPATCH_TOKEN }}
```
Checks out the deployment repo code to access docker-compose files, scripts, and monitoring config.

**Step 2: Extract service name**
```bash
if [ "${{ github.event_name }}" = "repository_dispatch" ]; then
  SERVICE="${{ github.event.client_payload.service }}"
  VERSION="${{ github.event.client_payload.version }}"
else
  SERVICE="${{ github.event.inputs.service || 'all' }}"
  VERSION="manual"
fi
```

Sets outputs for downstream steps.
- For dispatch: Reads service name and SHA from event payload
- For manual: Uses input or defaults to "all"

**Step 3: Update version file** (skipped for manual trigger)
```bash
# Convert service name: account-api → ACCOUNT_API_VERSION
ENV_VAR=$(echo "${SERVICE}" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_VERSION

# Update versions.env
sed -i "s|^${ENV_VAR}=.*|${ENV_VAR}=${VERSION}|" versions.env

# Commit and push (with retry logic)
git config user.name "GitHub Actions Bot"
git commit -m "deploy: update ${SERVICE} to ${VERSION}"
git push  # Retry up to 3 times if conflicts
```

This ensures `versions.env` is the single source of truth for deployment state in git history.

**Step 4: Deploy to VPS** (using `appleboy/ssh-action@v1.0.3`)
```bash
host: ${{ secrets.VPS_HOST }}
username: ${{ secrets.VPS_USERNAME }}
key: ${{ secrets.VPS_SSH_KEY }}
script: |
  cd /home/deploy/production/coachify
  bash scripts/deploy.sh "$SERVICE_NAME"
```

Executes deploy.sh on VPS with the service name.
- All services have same URL (nginx + docker DNS resolution)
- Service name used for logging/monitoring, not URL selection
- `pull_policy: always` in compose ensures fresh images fetched

**Step 5: Verify deployment**
Adds summary to GitHub Actions output showing service, version, and VPS host.

**Step 6: Rollback on failure** (only if previous steps fail)
```bash
script: |
  bash /home/deploy/production/coachify/scripts/rollback.sh
```

Automatic rollback triggered if health checks or deployment fails.

---

## 9. MONITORING DASHBOARD DEPLOYMENT

### Grafana Provisioning
**Path**: `monitoring/grafana/provisioning/`

**Datasources** (`datasources/prometheus.yml`):
```yaml
datasources:
  - name: Prometheus
    type: prometheus
    url: http://prometheus:9090
    access: proxy
    isDefault: true
```

**Dashboards** (`dashboards/dashboard.yml`):
```yaml
providers:
  - name: Coachify Dashboards
    type: file
    path: /var/lib/grafana/dashboards
    options:
      folder: General
```

Auto-loads JSON dashboards from `/var/lib/grafana/dashboards/` directory.

### Pre-built Dashboard
**File**: `monitoring/grafana/dashboards/coachify-overview.json`

Visualizations include:
- **Service Status**: Up/down indicator for each microservice
- **Request Volume**: Requests per second by service
- **Error Rates**: % of 5xx responses
- **Latency**: P50, P95, P99 percentiles
- **Resource Usage**: CPU and memory per container
- **Uptime**: Service availability over time

---

## 10. SECURITY CONSIDERATIONS

### Secrets Management
`.env.production` is NOT in git. Must be:
1. Stored in GitHub Actions secrets (for workflow access)
2. Stored in 1Password or similar vault
3. Injected into VPS via secure method (not shown in this repo)

### SSH Access
- VPS accepts SSH only from GitHub Actions runners (GitHub IPs)
- Private key (`VPS_SSH_KEY`) stored as GitHub secret
- Public key pre-installed on VPS in `~deploy/.ssh/authorized_keys`

### Image Registry Access
- GHCR images are public (no auth required for pulls)
- Image tags are git commit SHAs (explicit versioning)
- No `latest` tag used in production (prevents surprises)

### Network Security
- Services only accessible via nginx reverse proxy (external)
- Internal service-to-service traffic via Docker bridge network
- No ports exposed except nginx (80, 443)
- Grafana (3001) and Prometheus (9090) exposed but accessible only to VPS (not internet)

---

## 11. INCIDENT RESPONSE

### If a service is down:
1. Check `docker compose ps` on VPS
2. Read logs: `docker logs coachify-{service-name}`
3. Check Prometheus alerts at `http://vps-ip:9090/alerts`
4. If service crashed on startup:
   - Check `.env.production` for missing credentials
   - Check MongoDB/Redis connectivity
5. Manual rollback:
   ```bash
   ssh deploy@vps
   cd /home/deploy/production/coachify
   ./scripts/rollback.sh
   ```

### If deployment workflow fails:
1. Check GitHub Actions logs (workflow run details)
2. Common failures:
   - SSH authentication failure: Check `VPS_SSH_KEY` secret is valid
   - Health checks timeout: Service taking too long to start (database migrations?)
   - Image not found: Service repo didn't push image to GHCR

### If metrics are missing:
1. Verify service exports `/metrics` endpoint
2. Check `monitoring/prometheus.yml` includes the service
3. Restart Prometheus: `docker compose -f docker-compose.monitoring.yml restart prometheus`
4. Check Prometheus targets at `http://vps-ip:9090/targets`

---

## 12. LOCAL DEVELOPMENT / TESTING

### Preview Deployment Locally
```bash
# Copy docker-compose files locally
docker compose -f docker-compose.prod.yml config

# Validate compose file
docker compose -f docker-compose.prod.yml config --quiet

# Don't actually start without .env.production
# (will fail due to missing secrets)
```

### Test Monitoring Stack
```bash
docker compose -f docker-compose.monitoring.yml up -d

# Prometheus: http://localhost:9090
# Grafana: http://localhost:3001  (admin/admin by default)
# AlertManager: http://localhost:9093
```

---

## 13. DEPLOYMENT REPOSITORY SUMMARY

| Aspect | Value |
|--------|-------|
| **Primary Role** | Multi-service deployment orchestration and monitoring |
| **Deployment Method** | GitHub Actions → SSH → docker compose up -d |
| **Services Managed** | 10 Go microservices + 2 Next.js frontends + monitoring stack |
| **Configuration Language** | YAML (docker-compose, nginx, prometheus) + Bash (deploy scripts) |
| **Monitoring Backend** | Prometheus + Grafana + AlertManager |
| **State Storage** | `versions.env` (in git), deployment logs (on VPS) |
| **Orchestration Tool** | Docker Compose (single VPS, no Kubernetes) |
| **Secrets Management** | GitHub Actions secrets + .env.production (not in repo) |
| **Revision Control** | Git (tracks versions.env and deployment history) |
| **Infrastructure Provider** | Single VPS (Ubuntu 20.04+) |
| **CI/CD Trigger** | GitHub `repository_dispatch` events or manual workflow_dispatch |
| **Recovery Method** | Automatic rollback on health check failure |
| **Observability** | Prometheus metrics + Grafana dashboards + AlertManager routing |
