#!/usr/bin/env bash
# =============================================================================
# 02_create_admin_user.sh
# Bootstrap authentication on the new local MongoDB 6.0 instance.
# Idempotent: detects existing users and skips creation if already done.
#
# Required environment variables (set before running — never hardcode):
#   MONGO_ADMIN_USER      — admin username (role: root, in admin db)
#   MONGO_ADMIN_PASSWORD  — admin password
#   MONGO_APP_USER        — application username (readWrite on MONGO_APP_DB)
#   MONGO_APP_PASSWORD    — application password
#   MONGO_APP_DB          — application database name (e.g. coachify)
#
# Usage:
#   export MONGO_ADMIN_USER=adminUser
#   export MONGO_ADMIN_PASSWORD=yourStrongAdminPassword
#   export MONGO_APP_USER=coachifyApp
#   export MONGO_APP_PASSWORD=yourStrongAppPassword
#   export MONGO_APP_DB=coachify
#   sudo ./02_create_admin_user.sh
# =============================================================================
set -euo pipefail

MONGOD_CONF="/etc/mongod.conf"
LOGFILE="/var/log/mongodb-bootstrap.log"

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
die()     { log "ERROR" "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Validate required environment variables
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<'EOF'
Usage: set the following environment variables before running this script:

  MONGO_ADMIN_USER      Admin username to create (role: root, in admin db)
  MONGO_ADMIN_PASSWORD  Admin password
  MONGO_APP_USER        Application username (readWrite on MONGO_APP_DB only)
  MONGO_APP_PASSWORD    Application password
  MONGO_APP_DB          Application database name (e.g. coachify)

Example:
  export MONGO_ADMIN_USER=adminUser
  export MONGO_ADMIN_PASSWORD='str0ng!Admin#Pass'
  export MONGO_APP_USER=coachifyApp
  export MONGO_APP_PASSWORD='str0ng!AppPass#'
  export MONGO_APP_DB=coachify
  sudo ./02_create_admin_user.sh
EOF
  exit 1
}

validate_env() {
  local missing=0
  for var in MONGO_ADMIN_USER MONGO_ADMIN_PASSWORD MONGO_APP_USER MONGO_APP_PASSWORD MONGO_APP_DB; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: Required env var '${var}' is not set." >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || usage
}

# ---------------------------------------------------------------------------
# Wait until mongod accepts connections
# ---------------------------------------------------------------------------
wait_for_mongod() {
  local attempts=0
  local max=30
  info "Waiting for mongod to be ready on localhost:27017..."
  while ! mongosh --quiet --eval "db.adminCommand('ping')" &>/dev/null; do
    attempts=$(( attempts + 1 ))
    if (( attempts >= max )); then
      die "mongod did not become ready after ${max} seconds. Check: journalctl -xeu mongod"
    fi
    sleep 1
  done
  success "mongod is ready."
}

# ---------------------------------------------------------------------------
# Check if auth is already enabled in mongod.conf
# ---------------------------------------------------------------------------
auth_already_enabled() {
  grep -qE '^\s*authorization:\s*enabled' "$MONGOD_CONF" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Check if admin user already exists (requires no-auth connection)
# ---------------------------------------------------------------------------
admin_user_exists() {
  local result
  result="$(mongosh --quiet --eval \
    "db.getSiblingDB('admin').getUser('${MONGO_ADMIN_USER}')" \
    2>/dev/null || true)"
  [[ "$result" != "null" && -n "$result" ]]
}

# ---------------------------------------------------------------------------
# Create admin user (no-auth mode — first run only)
# ---------------------------------------------------------------------------
create_admin_user() {
  info "Creating admin user '${MONGO_ADMIN_USER}' in the admin database..."
  mongosh --quiet admin --eval "
    db.createUser({
      user: '${MONGO_ADMIN_USER}',
      pwd:  '${MONGO_ADMIN_PASSWORD}',
      roles: [{ role: 'root', db: 'admin' }],
      mechanisms: ['SCRAM-SHA-256']
    });
  "
  success "Admin user '${MONGO_ADMIN_USER}' created with role: root."
}

# ---------------------------------------------------------------------------
# Check if app user already exists (requires auth)
# ---------------------------------------------------------------------------
app_user_exists() {
  local result
  result="$(mongosh --quiet \
    "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASSWORD}@localhost:27017/admin?authSource=admin" \
    --eval "db.getSiblingDB('${MONGO_APP_DB}').getUser('${MONGO_APP_USER}')" \
    2>/dev/null || true)"
  [[ "$result" != "null" && -n "$result" ]]
}

# ---------------------------------------------------------------------------
# Create application user (readWrite on app DB only — not root)
# ---------------------------------------------------------------------------
create_app_user() {
  info "Creating app user '${MONGO_APP_USER}' with readWrite on '${MONGO_APP_DB}'..."
  mongosh --quiet \
    "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASSWORD}@localhost:27017/admin?authSource=admin" \
    --eval "
      db.getSiblingDB('${MONGO_APP_DB}').createUser({
        user: '${MONGO_APP_USER}',
        pwd:  '${MONGO_APP_PASSWORD}',
        roles: [{ role: 'readWrite', db: '${MONGO_APP_DB}' }],
        mechanisms: ['SCRAM-SHA-256']
      });
    "
  success "App user '${MONGO_APP_USER}' created with readWrite on '${MONGO_APP_DB}'."
}

# ---------------------------------------------------------------------------
# Enable authentication in mongod.conf
# ---------------------------------------------------------------------------
enable_auth() {
  if auth_already_enabled; then
    info "Authorization already enabled in ${MONGOD_CONF} — skipping."
    return
  fi

  info "Enabling authorization in ${MONGOD_CONF}..."
  # Replace the disabled block (written by 01_install_mongodb.sh)
  # If the file has the commented-out block, replace it; otherwise append.
  if grep -q 'authorization: disabled' "$MONGOD_CONF"; then
    sed -i 's/authorization: disabled/authorization: enabled/' "$MONGOD_CONF"
  elif grep -q '^security:' "$MONGOD_CONF"; then
    sed -i '/^security:/a\  authorization: enabled' "$MONGOD_CONF"
  else
    printf '\nsecurity:\n  authorization: enabled\n' >> "$MONGOD_CONF"
  fi

  success "Authorization enabled in ${MONGOD_CONF}."
}

# ---------------------------------------------------------------------------
# Verify that credentials work
# ---------------------------------------------------------------------------
verify_credentials() {
  info "Verifying admin credentials..."
  if ! mongosh --quiet \
    "mongodb://${MONGO_ADMIN_USER}:${MONGO_ADMIN_PASSWORD}@localhost:27017/admin?authSource=admin" \
    --eval "db.adminCommand('ping')" &>/dev/null; then
    die "Admin credentials verification failed. Check MONGO_ADMIN_USER / MONGO_ADMIN_PASSWORD."
  fi
  success "Admin credentials verified."

  info "Verifying app user credentials..."
  if ! mongosh --quiet \
    "mongodb://${MONGO_APP_USER}:${MONGO_APP_PASSWORD}@localhost:27017/${MONGO_APP_DB}?authSource=${MONGO_APP_DB}" \
    --eval "db.stats()" &>/dev/null; then
    die "App user credentials verification failed. Check MONGO_APP_USER / MONGO_APP_PASSWORD."
  fi
  success "App user credentials verified."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root (or via sudo)."
  fi

  info "========================================="
  info " MongoDB Authentication Bootstrap"
  info "========================================="

  validate_env
  wait_for_mongod

  # Phase 1: Create users while auth is still disabled
  if auth_already_enabled; then
    info "Auth is already enabled — skipping user creation in no-auth mode."
  else
    if admin_user_exists; then
      info "Admin user '${MONGO_ADMIN_USER}' already exists — skipping creation."
    else
      create_admin_user
    fi

    enable_auth
    info "Restarting mongod to activate auth..."
    systemctl restart mongod
    wait_for_mongod
  fi

  # Phase 2: Create app user (authenticated connection)
  if app_user_exists; then
    info "App user '${MONGO_APP_USER}' already exists — skipping creation."
  else
    create_app_user
  fi

  verify_credentials

  info "========================================="
  success "Authentication bootstrapped successfully."
  info ""
  info "  Admin URI : mongodb://${MONGO_ADMIN_USER}:***@localhost:27017/admin?authSource=admin"
  info "  App URI   : mongodb://${MONGO_APP_USER}:***@localhost:27017/${MONGO_APP_DB}?authSource=${MONGO_APP_DB}"
  info ""
  info "IMPORTANT: Use the app URI (not admin) in your microservice MONGODB_URI."
  info "Next step: run 03_clone_from_cluster.sh to copy production data."
  info "========================================="
}

main "$@"
