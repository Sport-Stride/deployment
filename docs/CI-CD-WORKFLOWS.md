# CI/CD & Deployment Workflows

Complete visualization of the automated deployment and integration workflows for Coachify.

---

## GitHub Actions: Frontend Build & Deploy Pipeline

```mermaid
graph LR
    subgraph "Developer Workflow"
        DEV["👨‍💻 Developer<br/>Commits to main"]
    end
    
    subgraph "GitHub Repository"
        GH["GitHub:coachify-client"]
        DEV -->|git push main| GH
    end
    
    subgraph "Build Workflow (.github/workflows/build.yml)"
        T1["⏲️ Trigger<br/>on: push main"]
        T2["🔐 Login to GHCR"]
        T3["🛠️ Build Docker Image<br/>with Build Args:<br/>NEXT_PUBLIC_ABLY_KEY<br/>NEXT_PUBLIC_API_URLS"]
        T4["📦 Push to GHCR<br/>ghcr.io/sport-stride<br/>coachify-frontend:{sha}"]
        T1 -->|Checkout code| T2
        T2 -->|Setup Buildx| T3
        T3 -->|Docker push| T4
    end
    
    subgraph "Event Dispatch"
        EVT["📤 Trigger Dispatch Event<br/>event_type: 'service-built'<br/>client_payload: {<br/>  service: 'frontend',<br/>  version: {commit_sha},<br/>  image_url: ...<br/>}"]
        T4 -->|After success| EVT
        EVT -->|Via DISPATCH_TOKEN| DEPLOY_REPO["GitHub:deployment"]
    end
    
    subgraph "Deploy Workflow (.github/workflows/deploy-to-vps.yml)"
        DT["⏲️ Trigger<br/>on: repository_dispatch"]
        DU["📝 Update versions.env<br/>FRONTEND_VERSION={sha}"]
        DC["🔐 Commit & push<br/>versions.env"]
        DT -->|Extract payload| DU
        DU -->|git commit| DC
    end
    
    subgraph "VPS Deployment"
        SSH["🔑 SSH to VPS<br/>54.37.225.78"]
        PULL["📥 Pull .env.production<br/>& versions.env"]
        DEPLOY["🚀 Execute deploy.sh<br/>docker compose pull<br/>docker compose up"]
        SSH -->|Run script| PULL
        PULL -->|Source env vars| DEPLOY
    end
    
    subgraph "Running Services"
        RUNNING["✅ Frontend running<br/>with NEXT_PUBLIC_ABLY_KEY<br/>Real-time chat enabled"]
        DEPLOY -->|Health check| RUNNING
    end
    
    DC -->|triggers| DT
    
    style T4 fill:#99ff99
    style EVT fill:#ffcc99
    style DEPLOY fill:#ccccff
    style RUNNING fill:#99ff99
```

**Timeline:**
- **Commit → Build**: 5-7 minutes (checkout, build, push)
- **Build → Deploy trigger**: Immediate (dispatch event)
- **Deploy trigger → VPS**: 2-3 minutes (pull images, restart)
- **Total**: ~10-15 minutes end-to-end

**Key Environment Variables Passed:**
- `NEXT_PUBLIC_ABLY_KEY` ✅ (now embedded in image)
- `NEXT_PUBLIC_API_URLS` (account, chat, workout, etc.)
- `NEXTAUTH_URL` (OAuth callback)
- `NEXT_PUBLIC_USE_PROXY=false` (bypass Next.js proxy)

---

## Manual Deployment Trigger (Workflow Dispatch)

```mermaid
graph TB
    subgraph "Manual Trigger"
        ADMIN["👨‍💼 Admin"]
        UI["GitHub Actions UI<br/>.github/workflows/deploy-to-vps.yml"]
        ADMIN -->|Click 'Run workflow'| UI
    end
    
    subgraph "Input Parameters"
        SERVICE["service: all<br/>(or specific service name)"]
        UI -->|Inputs| SERVICE
    end
    
    subgraph "Deploy Logic"
        EXTRACT["Extract service name"]
        SSH["SSH to VPS"]
        RUN["Run deploy.sh<br/>with service parameter"]
        EXTRACT -->|Parse input| SSH
        SSH -->|Execute| RUN
    end
    
    subgraph "Result"
        SUCCESS["✅ Service redeployed<br/>or all services updated"]
        RUN -->|Health check| SUCCESS
    end
    
    style UI fill:#ffcc99
    style EXTRACT fill:#ccccff
    style SUCCESS fill:#99ff99
```

**Usage:**
```bash
# Via GitHub UI: Actions tab → Deploy to VPS → Run workflow → Inputs: service=all
# Or specific service: service=account-api
```

---

## Local Development Deployment

```mermaid
graph TB
    subgraph "Developer Machine"
        DEV["👨‍💻 Developer<br/>Local environment"]
    end
    
    subgraph "Docker Compose (Local)"
        DC["docker-compose -f docker-compose.yml up -d"]
        SERVICES["All 10 services<br/>+ Frontend<br/>+ Nginx<br/>+ MongoDB"]
        DC -->|Start services| SERVICES
    end
    
    subgraph "Development Workflow"
        CODE["Edit code in IDE"]
        HOT["🔥 Hot reload<br/>(Frontend: Turbopack<br/>Backend: re-compile)"]
        TEST["🧪 Run tests<br/>go test ./..."]
        CODE -->|Save file| HOT
        HOT -->|Verify| TEST
    end
    
    subgraph "Local Testing"
        API["http://localhost:8080 → services<br/>http://localhost:3000 → frontend<br/>http://localhost:3001 → landing"]
        LOGS["docker logs {service}"]
        API -->|Debug| LOGS
    end
    
    DEV -->|docker-compose up| DC
    SERVICES -->|Auto-reload| HOT
    TEST -->|Integration test| API
    
    style DC fill:#99ff99
    style HOT fill:#ffcc99
```

---

## MongoDB Migration & Cutover Workflow

```mermaid
graph TB
    subgraph "Phase 1: Preparation"
        P1["✅ MongoDB installed locally"]
        P2["✅ Admin user created"]
        P1 -->|Next| P2
    end
    
    subgraph "Phase 2: Data Migration"
        P3["Clone data from Atlas"]
        P4["Source: sportstride.spdvs.mongodb.net/coachify"]
        P5["Target: localhost:27017/coachify"]
        P3 -->|Via| P4
        P4 -->|Arrow| P5
    end
    
    subgraph "Phase 3: Verification"
        P6["Compare collection counts"]
        P7["Verify indexes"]
        P8["Test queries"]
        P6 -->|Step 1| P7
        P7 -->|Step 2| P8
    end
    
    subgraph "Phase 4: Cutover"
        P9["Update .env.production:<br/>MONGODB_URI=mongodb://<br/>coachifyApp:pass@<br/>localhost:27017/coachify"]
        P10["Restart all services<br/>docker-compose restart"]
        P11["Verify health checks pass"]
        P9 -->|Then| P10
        P10 -->|Confirm| P11
    end
    
    subgraph "Phase 5: Monitoring"
        P12["🔍 Watch logs for<br/>connection errors"]
        P13["📊 Monitor latency<br/>(should decrease)"]
        P14["✅ Production stable"]
        P12 -->|Ongoing| P13
        P13 -->|If all good| P14
    end
    
    P2 -->|Next| P3
    P8 -->|Proceed| P9
    P11 -->|Enter| P12
    
    style P1 fill:#99ff99
    style P5 fill:#ccccff
    style P11 fill:#ffcc99
    style P14 fill:#99ff99
```

**Execution Commands:**
```bash
# Step 1: Install MongoDB
ssh deploy@54.37.225.78 "sudo bash /home/deploy/production/coachify/scripts/mongodb/01_install_mongodb.sh"

# Step 2: Create users
scp scripts/mongodb/02_create_admin_user.sh deploy@54.37.225.78:...
ssh deploy@54.37.225.78 "MONGO_ADMIN_USER=adminUser ... sudo bash scripts/mongodb/02_create_admin_user.sh"

# Step 3: Clone from Atlas
ssh deploy@54.37.225.78 "SOURCE_MONGO_URI='...' MONGO_ADMIN_USER=... sudo bash scripts/mongodb/03_clone_from_cluster.sh"

# Step 4: Verify
ssh deploy@54.37.225.78 "sudo bash scripts/mongodb/04_verify_restore.sh"

# Step 5: Cutover
ssh deploy@54.37.225.78 "NEW_MONGO_URI='mongodb://coachifyApp:pass@localhost:27017/coachify' sudo bash scripts/mongodb/05_cutover.sh"
```

---

## Complete Service Startup Order

```mermaid
graph TB
    subgraph "Phase 1: Infrastructure"
        INF1["🔐 Nginx container<br/>Status: healthy"]
        INF2["🗄️ MongoDB<br/>Status: ready"]
        INF3["⚡ Redis<br/>Status: ready"]
        INF1 -.->|Wait for| INF2
        INF2 -.->|Wait for| INF3
    end
    
    subgraph "Phase 2: Core Services (Parallel)"
        CORE1["🔑 identifier-api<br/>(8080)"]
        CORE2["👤 account-api<br/>(8082)"]
        CORE3["🗄️ MongoDB indexes<br/>init on startup"]
        CORE1 -.->|Parallel| CORE2
        CORE2 -.->|Connect| CORE3
    end
    
    subgraph "Phase 3: Dependent Services (Parallel)"
        DEP1["💬 chat-api<br/>(8083)"]
        DEP2["💪 workout-api<br/>(8084)"]
        DEP3["💳 payments-api<br/>(8085)"]
        DEP4["🎫 invitation-api<br/>(8086)"]
        DEP5["📚 content-api<br/>(8087)"]
        DEP6["📍 tracker-api<br/>(8088)"]
        DEP7["📈 statistics-api<br/>(8089)"]
        DEP8["📧 notification-api<br/>(8081)"]
        CORE2 -.->|HTTP ready| DEP1
        CORE2 -.->|HTTP ready| DEP2
        CORE2 -.->|HTTP ready| DEP3
        CORE2 -.->|HTTP ready| DEP4
        DEP1 -.->|Ready| DEP8
        DEP6 -.->|Ready| DEP7
    end
    
    subgraph "Phase 4: Frontend"
        FE["🌐 Frontend<br/>Next.js<br/>NEXT_PUBLIC_ABLY_KEY ready"]
        DEP3 -.->|Verified| FE
    end
    
    subgraph "Phase 5: Health Checks"
        HC["✅ All endpoints<br/>responding 200 OK"]
        FE -.->|Health check| HC
    end
    
    INF3 -->|Complete| CORE1
    CORE2 -->|Complete| DEP1
    DEP8 -->|Complete| FE
    HC -->|Result| HC
    
    style INF1 fill:#ff9999
    style CORE1 fill:#99ff99
    style DEP1 fill:#ffcc99
    style FE fill:#ccccff
    style HC fill:#99ff99
```

**Startup Timeline:**
- Infrastructure (MongoDB, Redis, Nginx): 15-20 seconds
- Core services (identifier, account): 5-10 seconds
- All microservices: 20-30 seconds (parallel)
- Frontend + health checks: 10-15 seconds
- **Total to healthy state**: ~60-90 seconds

---

## Rollback Strategy

```mermaid
graph TB
    subgraph "Backup Created"
        BAK1["🔄 On every deploy"]
        BAK2["Save: docker ps<br/>Save: docker images<br/>Save: docker logs"]
        BAK1 -->|Backup| BAK2
    end
    
    subgraph "Issue Detected"
        ISSUE["❌ Service failing<br/>❌ High latency<br/>❌ Data corruption"]
    end
    
    subgraph "Rollback Execution"
        RB1["bash scripts/rollback.sh"]
        RB2["Restore last good<br/>image versions"]
        RB3["docker-compose restart<br/>from previous version"]
        RB1 -->|Run| RB2
        RB2 -->|Pull| RB3
    end
    
    subgraph "Verification"
        VER1["Health checks pass"]
        VER2["Services responsive"]
        VER3["✅ System stable"]
        RB3 -->|Verify| VER1
        VER1 -->|Verify| VER2
        VER2 -->|Verify| VER3
    end
    
    subgraph "Recovery"
        REC["Post-incident review<br/>Investigation<br/>Fix & re-deploy"]
    end
    
    BAK2 -->|Stored| ISSUE
    ISSUE -->|Trigger| RB1
    VER3 -->|If failed| REC
    
    style BAK2 fill:#99ff99
    style ISSUE fill:#ff9999
    style RB1 fill:#ffcc99
    style VER3 fill:#99ff99
    style REC fill:#ccccff
```

**Rollback Command:**
```bash
ssh deploy@54.37.225.78 "cd /home/deploy/production/coachify && bash scripts/rollback.sh"
```

**Backup Location:** `/home/deploy/production/coachify/backups/backup-{timestamp}`

---

## Error Recovery Workflow

```mermaid
graph TB
    subgraph "Failure Detection"
        FD1["Health check fails<br/>or crash detected"]
        FD2["Monitor alert triggered"]
    end
    
    subgraph "Automatic Recovery"
        AR1["Docker Compose notices exit"]
        AR2["Container restart policy:<br/>restart: unless-stopped"]
        AR3["Service restarted<br/>(max_retries: 3)"]
        AR1 -->|Auto| AR2
        AR2 -->|Trigger| AR3
    end
    
    subgraph "Manual Intervention"
        MI1["If 3 retries fail"]
        MI2["Check logs:<br/>docker logs {service}"]
        MI3["Diagnose issue"]
        MI4["Fix & redeploy"]
        MI1 -->|Then| MI2
        MI2 -->|Analyze| MI3
        MI3 -->|Implement| MI4
    end
    
    subgraph "Root Causes Handled"
        RC1["✅ Port conflict → Find & fix"]
        RC2["✅ OOM → Check memory"]
        RC3["✅ MongoDB connection → Check URI"]
        RC4["✅ Env var missing → Update .env"]
    end
    
    FD1 -->|Detect| AR1
    AR3 -->|Success?| AR3
    AR3 -->|Fail 3x| MI1
    MI4 -->|Redeploy| RC1
    
    style AR1 fill:#99ff99
    style MI1 fill:#ff9999
    style RC1 fill:#ccccff
```

---

## Environment Variable Management

```mermaid
graph TB
    subgraph "Source: .env.production (VPS)"
        ENV1["On disk at:<br/>/home/deploy/production/coachify/.env.production"]
        ENV2["Contains secrets:<br/>MONGODB_URI<br/>NEXT_PUBLIC_ABLY_KEY<br/>STRIPE_API_KEY<br/>GOOGLE_OAUTH_SECRET"]
        ENV1 -->|Contains| ENV2
    end
    
    subgraph "Deploy Script Processing"
        DEPLOY1["deploy.sh runs"]
        DEPLOY2["source .env.production"]
        DEPLOY3["source versions.env"]
        DEPLOY4["Variables exported<br/>to docker-compose"]
        DEPLOY1 -->|First| DEPLOY2
        DEPLOY2 -->|Then| DEPLOY3
        DEPLOY3 -->|Finally| DEPLOY4
    end
    
    subgraph "Docker Compose Expansion"
        DC1["Reads .env.production"]
        DC2["Expands ${VAR} in compose"]
        DC3["Passes as ENV or build-arg"]
        DC4["Container receives env vars"]
        DC1 -->|Via shell| DC2
        DC2 -->|Substitutes| DC3
        DC3 -->|Receives| DC4
    end
    
    subgraph "Runtime Access"
        RT1["Node.js: process.env.VAR"]
        RT2["Go: os.Getenv('VAR')"]
        RT3["Viper config: viper.GetString"]
        DC4 -->|For Next.js| RT1
        DC4 -->|For Go| RT2
        DC4 -->|Via Viper| RT3
    end
    
    style ENV1 fill:#ff9999
    style DEPLOY2 fill:#ffcc99
    style DC3 fill:#ccccff
    style RT1 fill:#99ff99
```

**Critical Variables:**
```bash
# .env.production must have:
MONGODB_URI=mongodb://coachifyApp:pass@172.18.0.1:27017/coachify?authSource=coachify
NEXT_PUBLIC_ABLY_KEY=E7cr4g.32azzQ:...
NEXTAUTH_URL=https://app.coachify.tn
STRIPE_API_KEY=sk_live_...
GOOGLE_OAUTH_CLIENT_ID=...
GOOGLE_OAUTH_CLIENT_SECRET=...
```

---

## Deployment Checklist

```
✅ Pre-Deployment
  ☐ Code review completed
  ☐ Tests passing (local)
  ☐ Database migrations ready
  ☐ All .env variables updated on VPS

✅ Deployment
  ☐ Backup created (automatic)
  ☐ docker-compose pull succeeds
  ☐ docker-compose up succeeds
  ☐ Health checks pass

✅ Post-Deployment
  ☐ All services "Up" status
  ☐ Frontend loads without errors
  ☐ API endpoints responding
  ☐ Database queries working
  ☐ Real-time chat (Ably) connected
  ☐ No error logs in docker logs
  ☐ Performance metrics normal (p50 < 100ms)

✅ Rollback (if needed)
  ☐ bash scripts/rollback.sh executed
  ☐ Services restarted with previous version
  ☐ Health checks verified
  ☐ Service restored to stable state
```

---

**Last Updated:** May 10, 2026  
**Deployment System:** GitHub Actions + Docker Compose on VPS  
**Uptime Target:** 99.9%

