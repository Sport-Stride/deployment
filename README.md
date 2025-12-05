# Coachify Production Deployment Guide

**Table of Contents**
1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Phase 1: Registry Setup](#phase-1-registry-setup)
4. [Phase 2: VPS Infrastructure](#phase-2-vps-infrastructure)
5. [Phase 3: Deployment Repository](#phase-3-deployment-repository)
6. [Phase 4: CI/CD Workflows](#phase-4-cicd-workflows)
7. [Phase 5: First Deployment](#phase-5-first-deployment)
8. [Operations & Monitoring](#operations--monitoring)
9. [Troubleshooting](#troubleshooting)
10. [Security Checklist](#security-checklist)

---

## Architecture Overview

**Coachify** is a multi-microservice SaaS platform deployed on a single VPS using Docker Compose. The deployment follows enterprise best practices:

```
┌─────────────────────────────────────────────────────────────┐
│                     GitHub Repositories                      │
│ ┌──────────────┐ ┌──────────────┐        ┌──────────────┐   │
│ │ account-api  │ │  chat-api    │  ...   │ workout-api  │   │
│ │  (Go + GHA)  │ │ (Go + GHA)   │        │ (Go + GHA)   │   │
│ └──────────────┘ └──────────────┘        └──────────────┘   │
│        │                │                       │             │
│        └────────────────┼───────────────────────┘             │
│                         │                                     │
│         Build on push   │ (GitHub Actions)                    │
│         Push to GHCR    │                                     │
│                         ▼                                     │
│         ┌─────────────────────────────┐                      │
│         │ GHCR (Image Registry)       │                      │
│         │ ghcr.io/sport-stride/*      │                      │
│         └─────────────────────────────┘                      │
│                         │                                     │
│         Trigger deploy  │                                     │
│         workflow        │                                     │
│                         ▼                                     │
│         ┌─────────────────────────────┐                      │
│         │  deployment Repository      │                      │
│         │  (Infrastructure as Code)   │                      │
│         │  .github/workflows/         │                      │
│         │    deploy-to-vps.yml        │                      │
│         └─────────────────────────────┘                      │
└─────────────────────────────────────────────────────────────┘
                         │
        SSH Deploy       │
        (GitHub Actions) │
                         ▼
     ┌───────────────────────────────────┐
     │          VPS Production           │
     │  /home/deploy/production/coachify │
     │                                   │
     │  docker-compose.prod.yml          │
     │  .env.production                  │
     │  versions.env                     │
     │  scripts/deploy.sh                │
     │  nginx/, monitoring/              │
     │                                   │
     │  ┌─────────────────────────────┐  │
     │  │  Docker Containers:         │  │
     │  │  • nginx-proxy              │  │
     │  │  • frontend (Next.js)       │  │
     │  │  • account-api (Go)         │  │
     │  │  • chat-api (Go)            │  │
     │  │  • ... 8 more services ...  │  │
     │  │  • mongodb                  │  │
     │  │  • redis (cache)            │  │
     │  │  • prometheus               │  │
     │  │  • grafana                  │  │
     │  │  • alertmanager             │  │
     │  └─────────────────────────────┘  │
     └───────────────────────────────────┘
```

**Key Principles:**
- **Source Code**: Only on GitHub (in individual service repos).
- **Images**: Built in GitHub Actions, pushed to GHCR (ghcr.io).
- **VPS Deployment**: Docker Compose pulls pre-built images, **no compilation on VPS**.
- **Configuration**: Externalized in `.env.production` and `versions.env` (not in git).
- **Orchestration**: GitHub Actions SSH → `docker compose pull && up -d` → health checks → Slack notification.

---

## Prerequisites

### Local Machine
- Git and GitHub account
- Docker Desktop (for testing)
- SSH client
- Bash shell

### VPS Requirements
- **OS**: Ubuntu 20.04 LTS or later
- **Hardware**: 2 CPU cores, 4 GB RAM minimum (8 GB recommended for production)
- **Storage**: 50 GB (50% for OS + Docker, 50% for data volumes)
- **Network**: Public static IP, SSH access (port 22), HTTP/HTTPS (ports 80, 443)

### GitHub Requirements
- Organizations and repositories created:
  - `Sport-Stride/deployment` (this repo, for infra-as-code)
  - Individual service repos (e.g., `Sport-Stride/coachify-account-api`, etc.)
- GitHub Secrets configured (see Phase 4)

---

## Phase 1: Registry Setup

### Step 1.1: Create GitHub Container Registry (GHCR) Token

1. Go to **GitHub Settings > Developer settings > Personal access tokens > Tokens (classic)**.
2. Click **Generate new token (classic)**.
3. Set scopes: `write:packages`, `read:packages`, `delete:packages`.
4. Set expiration: 90 days (rotate regularly).
5. Click **Generate token** and **save the token securely** (you won't see it again).

### Step 1.2: Configure GitHub Actions Authentication

1. In your GitHub organization or personal account, go to **Settings > Secrets and variables > Actions > New repository secret**.
2. Add secrets:
   - `GHCR_TOKEN`: Paste the PAT from Step 1.1.
   - `GHCR_USERNAME`: Your GitHub username or organization name.

These will be used by build workflows to push images to GHCR.

### Step 1.3: Verify GHCR Access

Run locally:
```bash
echo $GHCR_TOKEN | docker login ghcr.io -u $GHCR_USERNAME --password-stdin
docker pull ghcr.io/sport-stride/coachify-account-api:latest  # Will fail initially (image not pushed yet), that's OK
docker logout ghcr.io
```

---

## Phase 2: VPS Infrastructure

### Step 2.1: SSH to VPS

```bash
ssh root@your-vps-ip-address
```

### Step 2.2: Create Deploy User

```bash
# Add deploy user (non-root for security)
adduser deploy --disabled-password --gecos ""
usermod -aG docker deploy  # Allow deploy user to run docker commands without sudo
usermod -aG sudo deploy    # Grant sudo access

# Create SSH directory for deploy user
sudo -u deploy mkdir -p /home/deploy/.ssh
sudo -u deploy chmod 700 /home/deploy/.ssh
```

### Step 2.3: Configure SSH Key Authentication

**On your local machine:**
```bash
ssh-keygen -t ed25519 -C "deploy@coachify" -f ~/.ssh/coachify_vps -N ""
cat ~/.ssh/coachify_vps.pub
```

**Back on VPS (as root):**
```bash
# Append public key to deploy user's authorized_keys
echo "YOUR_PUBLIC_KEY_FROM_ABOVE" | sudo tee -a /home/deploy/.ssh/authorized_keys
sudo chown deploy:deploy /home/deploy/.ssh/authorized_keys
sudo chmod 600 /home/deploy/.ssh/authorized_keys

# Test SSH login
su - deploy
ssh-agent
exit
```

**Store private key securely:**
```bash
# On local machine, copy private key to GitHub Secrets
cat ~/.ssh/coachify_vps
# Copy the output and add to GitHub Secrets as VPS_SSH_KEY
```

### Step 2.4: Install Docker

```bash
# Update system
apt-get update && apt-get upgrade -y

# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
rm get-docker.sh

# Install Docker Compose v2
sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose --version  # Verify

# Start Docker service
sudo systemctl start docker
sudo systemctl enable docker
```

### Step 2.5: Set Up Deployment Directory

```bash
# Create deployment directory
sudo mkdir -p /home/deploy/production/coachify
sudo chown -R deploy:deploy /home/deploy/production

# Create backup directory
sudo mkdir -p /home/deploy/production/coachify/backups
```

### Step 2.6: Configure Firewall

```bash
# Enable UFW
sudo ufw enable

# Allow SSH (must do before blocking anything!)
sudo ufw allow 22/tcp

# Allow HTTP and HTTPS
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Allow Docker (internal only, no need to expose)
# Docker uses bridge networking, no UFW rules needed

# Check status
sudo ufw status
```

### Step 2.7: Configure Swap (Optional but Recommended)

```bash
# Add 4GB swap file
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
sudo bash -c 'echo /swapfile none swap sw 0 0 >> /etc/fstab'
```

---

## Phase 3: Deployment Repository

### Step 3.1: Create Deployment Repository

1. Go to **GitHub > Create new repository**.
2. Name: `deployment`
3. Organization: `Sport-Stride`
4. Visibility: **Private**
5. Initialize with README.

### Step 3.2: Clone and Structure

```bash
git clone https://github.com/Sport-Stride/deployment.git
cd deployment

# Copy files from this guide into the repo
# Structure should be:
# deployment/
#   docker-compose.prod.yml          (registry-based compose)
#   .env.production.example           (template for secrets)
#   versions.env                      (tracks image versions)
#   coachify-app.service             (systemd unit)
#   .github/
#     workflows/
#       build-account-api.yml         (example build workflow)
#       build-chat-api.yml            (copy and customize)
#       build-content-api.yml         (copy and customize)
#       ... (repeat for all 10 services + frontend)
#       deploy-to-vps.yml             (central deploy orchestration)
#   scripts/
#     deploy.sh                       (on-VPS deployment script)
#     rollback.sh                     (on-VPS rollback script)
#   nginx/
#     nginx.conf
#     conf.d/
#       default.conf
#   monitoring/
#     prometheus.yml
#     alertmanager.yml
#     alerts.yml
#     grafana/
```

### Step 3.3: Commit and Push

```bash
git add .
git commit -m "Initial deployment repository setup"
git push origin main
```

---

## Phase 4: CI/CD Workflows

### Step 4.1: Add Build Workflows to Service Repos

**For each of the 10 microservices + frontend:**

1. Go to service repo (e.g., `Sport-Stride/coachify-account-api`).
2. Create `.github/workflows/build.yml` (copy from `build-account-api.yml` in deployment repo).
3. Customize `service_name` and `image_name` to match the service.
4. Commit and push.

**Example for account-api:**
```yaml
name: Build Account API
on:
  push:
    branches: [main]
    paths:
      - 'Dockerfile'
      - 'main.go'
      - 'go.mod'
      - 'go.sum'
      - 'app/**'
      - 'handlers/**'
      - 'models/**'

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ secrets.GHCR_USERNAME }}
          password: ${{ secrets.GHCR_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ghcr.io/sport-stride/coachify-account-api:${{ github.sha }}
            ghcr.io/sport-stride/coachify-account-api:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
      
      # Trigger deployment repo workflow
      - uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.DISPATCH_TOKEN }}
          script: |
            await github.rest.repos.createDispatchEvent({
              owner: 'Sport-Stride',
              repo: 'deployment',
              event_type: 'deploy',
              client_payload: {
                service: 'account-api',
                version: context.sha
              }
            })
```

### Step 4.2: Add Deploy Secrets to Deployment Repo

Go to `Sport-Stride/deployment > Settings > Secrets and variables > Actions > New repository secret`:

- `GHCR_TOKEN`: Same token from Phase 1.
- `GHCR_USERNAME`: GitHub username/org.
- `DISPATCH_TOKEN`: GitHub PAT with `repo` scope (for cross-repo events).
- `VPS_HOST`: VPS IP address (e.g., `192.168.1.100`).
- `VPS_USERNAME`: `deploy` (from Phase 2).
- `VPS_SSH_KEY`: Private key from Phase 2.4 (entire contents of ~/.ssh/coachify_vps).
- `SLACK_WEBHOOK` (optional): For deployment notifications.

### Step 4.3: Test Build Workflow

1. Push a small change to `coachify-account-api` repo (modify README or comment).
2. Go to **Actions tab** and watch the build workflow run.
3. Verify image is pushed to GHCR:
   ```bash
   docker pull ghcr.io/sport-stride/coachify-account-api:latest
   docker images | grep coachify-account-api
   ```

---

## Phase 5: First Deployment

### Step 5.1: Prepare VPS

SSH to VPS as deploy user:
```bash
ssh deploy@your-vps-ip-address

# Create .env.production from template
cd /home/deploy/production/coachify
cp .env.production.example .env.production

# Edit .env.production with actual values
nano .env.production

# Set correct permissions (readable only by deploy user)
chmod 600 .env.production

# Verify docker-compose.prod.yml is in place
ls -la docker-compose.prod.yml
```

### Step 5.2: Test Manual Deployment

```bash
# As deploy user on VPS:
cd /home/deploy/production/coachify

# Login to GHCR (one-time setup)
echo $GHCR_TOKEN | docker login ghcr.io -u $GHCR_USERNAME --password-stdin

# Dry-run (validate compose file)
docker-compose -f docker-compose.prod.yml config

# Pull images (first time will take a few minutes)
docker-compose -f docker-compose.prod.yml pull

# Start services
docker-compose -f docker-compose.prod.yml up -d --remove-orphans

# Check status
docker-compose -f docker-compose.prod.yml ps

# View logs
docker-compose -f docker-compose.prod.yml logs -f nginx-proxy

# Test health endpoint
curl http://localhost/health
```

### Step 5.3: Configure systemd Auto-Start (Optional)

```bash
# As root on VPS:
sudo cp /home/deploy/production/coachify/coachify-app.service /etc/systemd/system/

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable coachify-app
sudo systemctl start coachify-app

# Check status
sudo systemctl status coachify-app

# View logs
sudo journalctl -u coachify-app -f
```

### Step 5.4: Test Automated Deployment

1. In deployment repo, manually trigger the deploy workflow:
   - Go to **Actions > deploy-to-vps > Run workflow**.
   - Select **main** branch and click **Run workflow**.
2. Watch the workflow execute:
   - Should update `versions.env`
   - Should SSH to VPS
   - Should run `docker-compose pull && up -d`
   - Should run health checks
   - Should post Slack notification (if configured)

3. Verify on VPS:
   ```bash
   ssh deploy@your-vps-ip-address
   cd /home/deploy/production/coachify
   docker-compose -f docker-compose.prod.yml ps
   tail -f deploy.log
   ```

---

## Operations & Monitoring

### Daily Operations

**Check Service Health:**
```bash
ssh deploy@vps-ip
cd /home/deploy/production/coachify
docker-compose -f docker-compose.prod.yml ps

# View detailed logs for a service
docker-compose -f docker-compose.prod.yml logs account-api

# Follow logs in real-time
docker-compose -f docker-compose.prod.yml logs -f --tail=50
```

**Access Monitoring Dashboards:**
- **Prometheus**: http://your-vps-ip:9090
- **Grafana**: http://your-vps-ip:3000 (default admin/admin)
- **nginx-proxy**: http://your-vps-ip

### Handling Deployments

**Automatic Deployment:**
1. Developer pushes code to service repo.
2. GitHub Actions builds image, pushes to GHCR.
3. Service build workflow triggers deployment repo workflow.
4. Deployment workflow SSHes to VPS, pulls new image, starts container.
5. Slack notification sent (if configured).

**Manual Deployment (if needed):**
```bash
# On VPS, run deployment script directly
cd /home/deploy/production/coachify
bash scripts/deploy.sh

# Or manually
docker-compose -f docker-compose.prod.yml pull
docker-compose -f docker-compose.prod.yml up -d --remove-orphans
```

**View Deployment History:**
```bash
# GitHub Actions deployment logs (via web UI)
# VPS deployment logs
tail -100 /home/deploy/production/coachify/deploy.log
cat /home/deploy/production/coachify/last-backup.txt
```

### Scaling / Performance Tuning

To adjust service resource limits in `docker-compose.prod.yml`:

```yaml
services:
  account-api:
    deploy:
      resources:
        limits:
          cpus: '1.0'        # Increase from 0.75
          memory: 512M       # Increase from 256M
        reservations:
          cpus: '0.5'
          memory: 256M
```

Then redeploy:
```bash
docker-compose -f docker-compose.prod.yml up -d --remove-orphans
```

---

## Troubleshooting

### Build Workflow Fails

**Check logs in GitHub Actions:**
1. Go to service repo > Actions tab.
2. Click failed workflow.
3. Expand job to see error details.

**Common issues:**
- **Docker build timeout**: Increase `timeout-minutes` in workflow.
- **GHCR login fails**: Verify GHCR_TOKEN is set correctly in Secrets.
- **Compose validation fails**: Run `docker-compose config` locally to check syntax.

### Deployment Fails

**Check VPS deployment logs:**
```bash
ssh deploy@vps-ip
tail -100 /home/deploy/production/coachify/deploy.log
docker-compose -f docker-compose.prod.yml logs --all

# Check SSH access from GitHub Actions
# Manually test SSH: ssh -v deploy@vps-ip
```

**Common issues:**
- **SSH key authentication fails**: Verify VPS_SSH_KEY in Secrets.
- **docker-compose command not found**: Reinstall Docker Compose v2.
- **Image pull fails**: Check GHCR_TOKEN is valid; verify image exists in GHCR.

### Container Won't Start

```bash
ssh deploy@vps-ip
docker-compose -f docker-compose.prod.yml logs SERVICE_NAME

# Common causes:
# - Port already in use: docker ps | grep :PORT
# - Environment variable missing: docker exec SERVICE_NAME printenv
# - Volume permission denied: ls -la volumes/
```

### Health Checks Fail

```bash
# Test service health endpoint manually
curl -v http://localhost:SERVICE_PORT/health

# Check service logs for errors
docker-compose -f docker-compose.prod.yml logs SERVICE_NAME

# Verify DNS resolution
docker-compose exec nginx-proxy nslookup account-api
```

### Rollback to Previous Deployment

```bash
ssh deploy@vps-ip
cd /home/deploy/production/coachify

# Run rollback script
bash scripts/rollback.sh

# Or manually
docker-compose -f docker-compose.prod.yml down
docker-compose -f docker-compose.prod.yml up -d --remove-orphans
```

---

## Security Checklist

- [ ] SSH key-based authentication configured (no password auth).
- [ ] UFW firewall enabled and restricted to needed ports (22, 80, 443).
- [ ] `.env.production` file exists on VPS with `chmod 600` permissions.
- [ ] `.env.production` is **NOT** committed to git (add to `.gitignore`).
- [ ] GitHub Secrets configured for all sensitive values (VPS_SSH_KEY, GHCR_TOKEN, etc.).
- [ ] GHCR token has minimal scopes (`write:packages`, `read:packages`).
- [ ] Regular token rotation schedule (e.g., every 90 days).
- [ ] systemd service runs as non-root `deploy` user (not root).
- [ ] Docker socket permissions: `sudo usermod -aG docker deploy`.
- [ ] VPS OS and Docker updated regularly (`apt update && apt upgrade`).
- [ ] Monitoring alerts configured for service failures.
- [ ] Backup strategy documented (or implement incremental backups to S3).
- [ ] SSL/TLS certificates obtained (Let's Encrypt via Certbot) and auto-renewal configured.
- [ ] Rate limiting and DDoS protection configured on nginx (optional).

---

## Maintenance

### Regular Tasks

**Weekly:**
- Check monitoring dashboards (Prometheus, Grafana).
- Review error logs for any issues.

**Monthly:**
- Review and clean up unused Docker images: `docker image prune -a`.
- Check VPS disk space: `df -h`.
- Verify backups are being created.

**Quarterly:**
- Rotate GitHub PAT tokens (GHCR_TOKEN, DISPATCH_TOKEN).
- Update Docker and system packages.
- Test rollback procedure.

### Backup Strategy (Advanced)

For production, implement off-site backups:

```bash
# Backup MongoDB data to S3
aws s3 cp /home/deploy/production/coachify/volumes/mongodb /s3://coachify-backups/mongodb --recursive

# Or use automated backup service
# - MongoDB Atlas (if using managed service)
# - S3 periodic backups via cron job
# - GitHub Actions scheduled workflow for backup job
```

---

## Support & Documentation

- **GitHub Issues**: Report bugs or request features in respective repos.
- **Monitoring**: Prometheus http://vps-ip:9090, Grafana http://vps-ip:3000.
- **Logs**: SSH to VPS and review `deploy.log` and `docker-compose logs`.
- **Community**: Join Discord or Slack channel for support.

---

**Last Updated:** $(date)
**Maintained by:** Sport Stride DevOps Team
