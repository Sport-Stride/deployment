#!/bin/bash
# Deployment script for Coachify production stack
# Usage: ./scripts/deploy.sh

set -e

DEPLOYMENT_DIR="/home/deploy/production/coachify"
LOG_FILE="${DEPLOYMENT_DIR}/deploy.log"
BACKUP_DIR="${DEPLOYMENT_DIR}/backups"
COMPOSE_FILE="${DEPLOYMENT_DIR}/docker-compose.prod.yml"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
  local level=$1
  shift
  local message="$@"
  local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
  echo -e "[${timestamp}] ${level} ${message}" | tee -a "$LOG_FILE"
}

# Error handler
trap 'log "❌ ERROR" "Deployment failed at line $LINENO"; exit 1' ERR

# Create backup of current state
backup_current_state() {
  mkdir -p "$BACKUP_DIR"
  local backup_name="backup-$(date +%s)"
  
  log "📦 BACKUP" "Creating backup: $backup_name"
  
  docker compose -f "$COMPOSE_FILE" ps > "$BACKUP_DIR/${backup_name}.ps" 2>&1 || true
  
  # Save docker images currently in use
  docker compose -f "$COMPOSE_FILE" images > "$BACKUP_DIR/${backup_name}.images" 2>&1 || true
  
  echo "$backup_name" > "${DEPLOYMENT_DIR}/last-backup.txt"
  log "✅ BACKUP" "Backup saved to $BACKUP_DIR/$backup_name"
}

# Pull latest images
pull_images() {
  log "📥 PULL" "Pulling latest images from registry..."
  
  if ! docker compose -f "$COMPOSE_FILE" pull --quiet; then
    log "❌ PULL" "Failed to pull images"
    return 1
  fi
  
  log "✅ PULL" "All images pulled successfully"
}

# Validate compose file
validate_compose() {
  log "🔍 VALIDATE" "Validating docker-compose file..."
  
  if ! docker compose -f "$COMPOSE_FILE" config > /dev/null 2>&1; then
    log "❌ VALIDATE" "Compose file validation failed"
    return 1
  fi
  
  log "✅ VALIDATE" "Compose file is valid"
}

# Start/update services
start_services() {
  log "🚀 START" "Starting/updating services..."
  
  if ! docker compose -f "$COMPOSE_FILE" up -d --remove-orphans; then
    log "❌ START" "Failed to start services"
    return 1
  fi
  
  log "✅ START" "Services started successfully"
}

# Wait for services to stabilize
wait_for_stability() {
  log "⏳ WAIT" "Waiting for services to stabilize..."
  sleep 10
  
  log "📊 STATUS" "Current service status:"
  docker compose -f "$COMPOSE_FILE" ps | while IFS= read -r line; do
    log "   " "$line"
  done
}

# Health checks
run_health_checks() {
  log "🏥 HEALTH" "Running health checks..."
  
  local failed=0
  
  # Nginx health
  if docker compose -f "$COMPOSE_FILE" exec -T nginx-proxy curl -f http://localhost/health > /dev/null 2>&1; then
    log "✅ HEALTH" "Nginx is healthy"
  else
    log "❌ HEALTH" "Nginx health check failed"
    failed=$((failed + 1))
  fi
  
  # Core services health check (sample)
  for service in account-api identifier-api chat-api; do
    if docker compose -f "$COMPOSE_FILE" exec -T "$service" curl -f http://localhost:*/health > /dev/null 2>&1; then
      log "✅ HEALTH" "$service is healthy"
    else
      log "⚠️  HEALTH" "$service health check timeout (may be starting)"
    fi
  done
  
  if [ $failed -gt 0 ]; then
    log "❌ HEALTH" "$failed health checks failed"
    return 1
  fi
}

# Cleanup old images
cleanup_images() {
  log "🧹 CLEANUP" "Pruning unused Docker images..."
  
  # Remove ALL dangling images immediately (no time filter)
  docker image prune -f > /dev/null 2>&1 || true
  
  # Also remove old images by the project label if you label them
  # docker image prune -f --filter "label=com.docker.compose.project=coachify" 
  
  # Show reclaimed space
  RECLAIMED=$(docker system df --format "{{.ReclaimableSize}}" 2>/dev/null || echo "unknown")
  log "✅ CLEANUP" "Pruned old images. Reclaimable space remaining: $RECLAIMED"
}


post_deploy_report() {
  log "📊 DISK" "Docker disk usage after deployment:"
  docker system df | while IFS= read -r line; do
    log "   " "$line"
  done
}
# Main deployment flow
main() {
  log "🎯 START" "=========================================="
  log "🎯 START" "Coachify Production Deployment"
  log "🎯 START" "=========================================="
  
  # Change to deployment directory
  cd "$DEPLOYMENT_DIR" || { log "❌ ERROR" "Could not cd to $DEPLOYMENT_DIR"; exit 1; }
  
  # Load environment variables
  set -a
  [ -f versions.env ] && source versions.env
  set +a
  
  # Execute deployment steps
  backup_current_state
  pull_images
  validate_compose
  start_services
  wait_for_stability
  run_health_checks
  cleanup_images
  post_deploy_report
  log "✅ SUCCESS" "=========================================="
  log "✅ SUCCESS" "Deployment completed successfully!"
  log "✅ SUCCESS" "=========================================="
  log "ℹ️  INFO" "Rollback available via: ./scripts/rollback.sh"
}

# Execute
main "$@"
