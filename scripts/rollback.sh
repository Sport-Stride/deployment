#!/bin/bash
# Rollback script - restores to previous deployment
# Usage: ./scripts/rollback.sh

set -e

DEPLOYMENT_DIR="/home/deploy/production/coachify"
LOG_FILE="${DEPLOYMENT_DIR}/deploy.log"
BACKUP_DIR="${DEPLOYMENT_DIR}/backups"
COMPOSE_FILE="${DEPLOYMENT_DIR}/docker-compose.prod.yml"

log() {
  local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] $@" | tee -a "$LOG_FILE"
}

# Get last backup
LAST_BACKUP=$(cat "${DEPLOYMENT_DIR}/last-backup.txt" 2>/dev/null || echo "")

if [ -z "$LAST_BACKUP" ]; then
  log "❌ ERROR: No backup found"
  exit 1
fi

log "⚠️  ROLLBACK: Starting rollback to backup: $LAST_BACKUP"

cd "$DEPLOYMENT_DIR"

# Graceful shutdown
log "🛑 ROLLBACK: Stopping services..."
docker compose -f "$COMPOSE_FILE" down || true

# Restart services (will pull current versions from compose)
log "🔄 ROLLBACK: Restarting services..."
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

sleep 5

# Verify
log "🏥 ROLLBACK: Verifying services..."
if docker compose -f "$COMPOSE_FILE" exec -T nginx-proxy curl -f http://localhost/health > /dev/null 2>&1; then
  log "✅ ROLLBACK: Rollback successful"
else
  log "⚠️  ROLLBACK: Services may still be starting..."
fi

docker compose -f "$COMPOSE_FILE" ps
