#!/usr/bin/env bash
# =============================================================================
# 05_cutover.sh
# Switch all Coachify microservices from the Atlas cluster to the local
# MongoDB instance. This is the ONLY step that modifies running services.
#
# What this script does:
#   1. Backs up .env.production with a timestamp before any edit
#   2. Replaces MONGODB_URI (and known aliases) with the new local URI
#   3. Leaves the old Atlas URI commented out in the env file for 48h safety
#   4. Restarts each affected Docker Compose service one at a time
#   5. Hits each service's health endpoint and asserts HTTP 200
#   6. Prints a final summary table
#
# Required environment variables:
#   NEW_MONGO_URI       — The new local MongoDB URI for all microservices
#                         (use the app user, not admin)
#                         e.g. mongodb://coachifyApp:pass@localhost:27017/coachify?authSource=coachify
#
# Optional environment variables:
#   COMPOSE_FILE        — Path to docker-compose file
#                         (default: /home/deploy/production/coachify/docker-compose.prod.yml)
#   ENV_FILE            — Path to the env file to update
#                         (default: /home/deploy/production/coachify/.env.production)
#   HEALTH_TIMEOUT      — Seconds to wait for a service to become healthy (default: 60)
#
# Usage:
#   export NEW_MONGO_URI="mongodb://coachifyApp:pass@localhost:27017/coachify?authSource=coachify"
#   ./05_cutover.sh
#
# NOTE: Run 04_verify_restore.sh first. Do not cut over if it exits non-zero.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (override via environment variables)
# ---------------------------------------------------------------------------
COMPOSE_FILE="${COMPOSE_FILE:-/home/deploy/production/coachify/docker-compose.prod.yml}"
ENV_FILE="${ENV_FILE:-./.env.production}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
LOGFILE="./mongodb-cutover.log"

# Microservice health endpoints (internal Docker network names → host ports exposed by nginx)
# Checks are performed via nginx to confirm end-to-end availability.
# Format: "service_name|container_name|health_url"
declare -a SERVICES=(
  "identifier-api|coachify-identifier-api|http://localhost/api/identifier/"
  "notification-api|coachify-notification-api|http://localhost/api/notification/"
  "account-api|coachify-account-api|http://localhost/api/account/"
  "chat-api|coachify-chat-api|http://localhost/api/chat/"
  "content-api|coachify-content-api|http://localhost/api/content/"
  "invitation-api|coachify-invitation-api|http://localhost/api/invitation/"
  "payments-api|coachify-payments-api|http://localhost/api/payments/"
  "workout-api|coachify-workout-api|http://localhost/api/workout/"
  "tracker-api|coachify-tracker-api|http://localhost/api/tracker/"
  "statistics-api|coachify-statistics-api|http://localhost/api/statistics/"
)

# Env var names to replace (all map to the same new value)
declare -a MONGO_URI_KEYS=(
  "MONGODB_URI"
  "DATABASE_URL"
  "MONGO_URI"
  "DB_URI"
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local level="$1"; shift
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] [${level}] $*" | tee -a "$LOGFILE"
}

info()    { log "INFO " "$@"; }
success() { log "OK   " "$@"; }
warn()    { log "WARN " "$@"; }
die()     { log "ERROR" "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Usage / validation
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<'EOF'
Usage: set the following environment variable before running this script:

  NEW_MONGO_URI   The new local MongoDB URI for all microservices
                  Use the application user (readWrite), NOT the admin user.

Example:
  export NEW_MONGO_URI="mongodb://coachifyApp:pass@localhost:27017/coachify?authSource=coachify"
  ./05_cutover.sh

Optional overrides:
  COMPOSE_FILE    Path to docker-compose.prod.yml
  ENV_FILE        Path to .env.production
  HEALTH_TIMEOUT  Seconds to wait for service health (default: 60)
EOF
  exit 1
}

validate_env() {
  if [[ -z "${NEW_MONGO_URI:-}" ]]; then
    echo "ERROR: Required env var 'NEW_MONGO_URI' is not set." >&2
    usage
  fi
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    die "Compose file not found: ${COMPOSE_FILE}. Set COMPOSE_FILE env var."
  fi
  if [[ ! -f "$ENV_FILE" ]]; then
    die "Env file not found: ${ENV_FILE}. Set ENV_FILE env var."
  fi
}

# ---------------------------------------------------------------------------
# Verify required tools
# ---------------------------------------------------------------------------
check_tools() {
  for tool in docker curl sed grep; do
    command -v "$tool" &>/dev/null || die "'${tool}' not found in PATH."
  done
  # Verify docker compose v2
  docker compose version &>/dev/null || die "'docker compose' (v2) not available."
  info "Required tools present."
}

# ---------------------------------------------------------------------------
# Backup env file
# ---------------------------------------------------------------------------
backup_env_file() {
  local ts; ts="$(date '+%Y%m%d_%H%M%S')"
  local backup="${ENV_FILE}.bak.${ts}"
  cp "$ENV_FILE" "$backup"
  success "Env file backed up to: ${backup}"
}

# ---------------------------------------------------------------------------
# Replace MONGODB_URI (and aliases) in the env file
# Leaves the old value commented out for 48h reference
# ---------------------------------------------------------------------------
update_env_file() {
  info "Updating MongoDB URI in ${ENV_FILE}..."

  local replaced=0

  for key in "${MONGO_URI_KEYS[@]}"; do
    # Look for lines that set this key (not already commented out)
    if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
      local old_line
      old_line="$(grep -E "^${key}=" "$ENV_FILE" | head -1)"
      local old_uri
      old_uri="$(echo "$old_line" | cut -d= -f2-)"

      info "  Found '${key}' — current value: ${old_uri:0:60}..."

      # Comment out the old line and insert the new one after it
      # Use a temp file to avoid sed -i portability issues
      local tmpfile; tmpfile="$(mktemp)"
      awk -v key="$key" -v old="$old_line" -v new_uri="$NEW_MONGO_URI" '
        $0 == old {
          print "# [CUTOVER] Old Atlas URI — remove after 48h of stable operation:"
          print "# " $0
          print key "=" new_uri
          next
        }
        { print }
      ' "$ENV_FILE" > "$tmpfile"
      mv "$tmpfile" "$ENV_FILE"

      success "  Replaced '${key}' with new local URI."
      replaced=$(( replaced + 1 ))
    fi
  done

  if [[ $replaced -eq 0 ]]; then
    # None of the known keys were found — append the new URI
    warn "No known MONGO_URI key found in ${ENV_FILE}. Appending MONGODB_URI."
    printf '\n# Added by 05_cutover.sh\nMONGODB_URI=%s\n' "$NEW_MONGO_URI" >> "$ENV_FILE"
  fi

  info "Env file updated. ${replaced} key(s) replaced."
}

# ---------------------------------------------------------------------------
# Restart a single service and wait for healthy state
# ---------------------------------------------------------------------------
restart_service() {
  local service="$1"
  local container="$2"
  local health_url="$3"

  info "Restarting service: ${service}..."
  docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate "$service"
  success "  docker compose up issued for ${service}."

  info "  Waiting up to ${HEALTH_TIMEOUT}s for ${service} to become healthy..."
  local elapsed=0
  local healthy=false

  while (( elapsed < HEALTH_TIMEOUT )); do
    local http_status
    http_status="$(curl -s -o /dev/null -w "%{http_code}" \
      --connect-timeout 3 --max-time 5 \
      "${health_url}" 2>/dev/null || echo "000")"

    if [[ "$http_status" == "200" ]]; then
      healthy=true
      break
    fi
    sleep 2
    elapsed=$(( elapsed + 2 ))
    info "    ${service}: HTTP ${http_status} (${elapsed}s elapsed)..."
  done

  if [[ "$healthy" == "true" ]]; then
    success "  ${service} is healthy (HTTP 200 from ${health_url})."
    echo "PASS"
  else
    warn "  ${service} did NOT return HTTP 200 within ${HEALTH_TIMEOUT}s."
    warn "  Last response: HTTP ${http_status:-unknown} from ${health_url}"
    warn "  Check logs: docker compose -f ${COMPOSE_FILE} logs ${service}"
    echo "FAIL"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "========================================="
  info " MongoDB Cutover — Atlas → Local"
  info "========================================="
  info " Compose file : ${COMPOSE_FILE}"
  info " Env file     : ${ENV_FILE}"
  info " New URI      : ${NEW_MONGO_URI:0:60}..."
  info "========================================="

  validate_env
  check_tools

  # Step 1: Back up env file before any edits
  backup_env_file

  # Step 2: Update the env file
  update_env_file

  # Step 3: Restart each service one at a time
  declare -A results
  info "Restarting affected microservices (one at a time)..."
  info ""

  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r svc_name container_name health_url <<< "$entry"
    result="$(restart_service "$svc_name" "$container_name" "$health_url")"
    results["$svc_name"]="$result"
    # Brief pause between restarts to let the service stabilize
    sleep 3
  done

  # Step 4: Print final summary table
  info ""
  info "========================================="
  info " Cutover Summary"
  info "========================================="
  printf "%-30s %-12s %s\n" "SERVICE" "HEALTH" "HEALTH_URL"
  printf "%-30s %-12s %s\n" "-------" "------" "----------"

  local all_healthy=true
  for entry in "${SERVICES[@]}"; do
    IFS='|' read -r svc_name container_name health_url <<< "$entry"
    local status="${results[$svc_name]:-UNKNOWN}"
    printf "%-30s %-12s %s\n" "$svc_name" "$status" "$health_url"
    if [[ "$status" != "PASS" ]]; then
      all_healthy=false
    fi
  done

  info ""
  info "Env file modified : ${ENV_FILE}"
  info "Old URI commented : yes (search for '# [CUTOVER]' in env file)"
  info ""

  if [[ "$all_healthy" == "true" ]]; then
    success "All services are healthy. Cutover complete."
    info ""
    info "Post-cutover checklist:"
    info "  [ ] Monitor Grafana dashboards for error rate spikes"
    info "  [ ] Watch application logs for MongoDB connection errors"
    info "  [ ] Run 04_verify_restore.sh daily for 48h to confirm data consistency"
    info "  [ ] Set up mongodump cron on local instance before decommissioning Atlas"
    info "  [ ] After 48h stable operation, remove commented Atlas URI from env file"
    info "  [ ] Do NOT decommission Atlas cluster until at least one local backup completes"
  else
    warn "One or more services failed health checks after restart."
    warn "Check Docker logs for failing services."
    warn "The env file has already been updated — if you need to roll back:"
    warn "  cp ${ENV_FILE}.bak.<TIMESTAMP> ${ENV_FILE}"
    warn "  docker compose -f ${COMPOSE_FILE} up -d --no-deps <service>"
    exit 1
  fi
  info "========================================="
}

main "$@"
