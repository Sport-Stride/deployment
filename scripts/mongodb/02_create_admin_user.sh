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
warn()    { log "WARN " "$@"; }
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
# JS string escaping — escape \ and " for embedding in JS double-quoted strings.
# This avoids MongoParseError from special characters (!, @, #, etc.) when
# mongosh 2.x internally constructs a URI from --username/--password flags.
# ---------------------------------------------------------------------------
js_escape() {
  local s="$1"
  s="${s//\\/\\\\}"  # backslash first
  s="${s//\"/\\\"}"  # then double-quote
  printf '%s' "$s"
}

# Run arbitrary JS body against local mongod using a temp file.
# Never passes credentials as CLI args — avoids all URI parsing issues.
run_mongosh_file() {
  local js_body="$1"
  local tmp; tmp="$(mktemp /tmp/.mongo-XXXXXXXX.js)"
  chmod 600 "$tmp"
  # shellcheck disable=SC2064
  trap "rm -f '${tmp}'" RETURN
  printf '%s\n' "$js_body" > "$tmp"
  mongosh --quiet --host 127.0.0.1 --port 27017 "$tmp"
}

# Run JS body authenticated as admin via db.auth() inside the script.
# This is the core fix: no --password CLI arg, so no MongoParseError.
run_mongosh_authed() {
  local js_body="$1"
  local esc_user; esc_user="$(js_escape "${MONGO_ADMIN_USER}")"
  local esc_pass; esc_pass="$(js_escape "${MONGO_ADMIN_PASSWORD}")"
  run_mongosh_file "
    var _ok = db.getSiblingDB('admin').auth(\"${esc_user}\", \"${esc_pass}\");
    if (!_ok) { throw new Error('Admin authentication failed — wrong credentials?'); }
    ${js_body}
  "
}

# ---------------------------------------------------------------------------
# Wait until mongod accepts connections
# ---------------------------------------------------------------------------
wait_for_mongod() {
  local attempts=0
  local max=30
  info "Waiting for mongod to be ready on 127.0.0.1:27017..."
  while ! mongosh --quiet --host 127.0.0.1 --port 27017 --eval "db.adminCommand('ping')" &>/dev/null; do
    attempts=$(( attempts + 1 ))
    if (( attempts >= max )); then
      die "mongod did not become ready after ${max} seconds. Check: journalctl -xeu mongod"
    fi
    sleep 1
  done
  success "mongod is ready."
}

admin_can_authenticate() {
  run_mongosh_authed "db.adminCommand('ping');" &>/dev/null
}

# ---------------------------------------------------------------------------
# Reset admin user: temporarily disable auth, drop all admin users,
# recreate with current credentials, re-enable auth.
# Used when auth is enabled but the admin password has changed/is unknown.
# ---------------------------------------------------------------------------
reset_admin_user() {
  warn "Cannot authenticate — resetting admin user (temporarily disabling auth)..."
  sed -i 's/authorization: enabled/authorization: disabled/' "$MONGOD_CONF"
  info "Restarting mongod without auth to perform reset..."
  systemctl restart mongod
  wait_for_mongod

  info "Dropping all existing admin users..."
  run_mongosh_file "
    var res = db.getSiblingDB('admin').getUsers();
    res.users.forEach(function(u) {
      db.getSiblingDB('admin').dropUser(u.user);
      print('Dropped user: ' + u.user);
    });
  "
  create_admin_user

  info "Re-enabling authorization..."
  sed -i 's/authorization: disabled/authorization: enabled/' "$MONGOD_CONF"
  info "Restarting mongod with auth..."
  systemctl restart mongod
  wait_for_mongod
  success "Admin user reset complete."
}

# ---------------------------------------------------------------------------
# Check if auth is already enabled in mongod.conf
# ---------------------------------------------------------------------------
auth_already_enabled() {
  grep -qE '^\s*authorization:\s*enabled' "$MONGOD_CONF" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Create admin user — works in no-auth mode AND via MongoDB localhost exception
# (localhost exception lets you create the FIRST admin user from localhost
# even with auth enabled, as long as no admin users exist yet).
# ---------------------------------------------------------------------------
create_admin_user() {
  info "Creating admin user '${MONGO_ADMIN_USER}' in the admin database..."
  local esc_user; esc_user="$(js_escape "${MONGO_ADMIN_USER}")"
  local esc_pass; esc_pass="$(js_escape "${MONGO_ADMIN_PASSWORD}")"
  if run_mongosh_file "
    db.getSiblingDB('admin').createUser({
      user:  \"${esc_user}\",
      pwd:   \"${esc_pass}\",
      roles: [{ role: 'root', db: 'admin' }],
      mechanisms: ['SCRAM-SHA-256']
    });
  "; then
    success "Admin user '${MONGO_ADMIN_USER}' created."
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# App user helpers
# ---------------------------------------------------------------------------
app_user_exists() {
  local esc_app_user; esc_app_user="$(js_escape "${MONGO_APP_USER}")"
  local esc_app_db;   esc_app_db="$(js_escape "${MONGO_APP_DB}")"
  run_mongosh_authed "
    var u = db.getSiblingDB(\"${esc_app_db}\").getUser(\"${esc_app_user}\");
    if (u !== null) { quit(0); } else { quit(1); }
  " &>/dev/null
}

create_app_user() {
  info "Creating app user '${MONGO_APP_USER}' with readWrite on '${MONGO_APP_DB}'..."
  local esc_app_user; esc_app_user="$(js_escape "${MONGO_APP_USER}")"
  local esc_app_pass; esc_app_pass="$(js_escape "${MONGO_APP_PASSWORD}")"
  local esc_app_db;   esc_app_db="$(js_escape "${MONGO_APP_DB}")"
  run_mongosh_authed "
    var existing = db.getSiblingDB(\"${esc_app_db}\").getUser(\"${esc_app_user}\");
    if (existing !== null) {
      print('App user already exists — updating password only.');
      db.getSiblingDB(\"${esc_app_db}\").updateUser(\"${esc_app_user}\", { pwd: \"${esc_app_pass}\" });
    } else {
      db.getSiblingDB(\"${esc_app_db}\").createUser({
        user:  \"${esc_app_user}\",
        pwd:   \"${esc_app_pass}\",
        roles: [{ role: 'readWrite', db: \"${esc_app_db}\" }],
        mechanisms: ['SCRAM-SHA-256']
      });
    }
  "
  success "App user '${MONGO_APP_USER}' ready on '${MONGO_APP_DB}'."
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
# Verify both sets of credentials work
# ---------------------------------------------------------------------------
verify_credentials() {
  info "Verifying admin credentials..."
  run_mongosh_authed "db.adminCommand('ping');" &>/dev/null \
    || die "Admin credentials verification failed. Check MONGO_ADMIN_USER / MONGO_ADMIN_PASSWORD."
  success "Admin credentials verified."

  info "Verifying app user credentials..."
  local esc_app_user; esc_app_user="$(js_escape "${MONGO_APP_USER}")"
  local esc_app_pass; esc_app_pass="$(js_escape "${MONGO_APP_PASSWORD}")"
  local esc_app_db;   esc_app_db="$(js_escape "${MONGO_APP_DB}")"
  run_mongosh_file "
    var _ok = db.getSiblingDB(\"${esc_app_db}\").auth(\"${esc_app_user}\", \"${esc_app_pass}\");
    if (!_ok) { throw new Error('App user auth failed'); }
    db.getSiblingDB(\"${esc_app_db}\").stats();
  " &>/dev/null || die "App user credentials verification failed. Check MONGO_APP_USER / MONGO_APP_PASSWORD."
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

  # Phase 1: Ensure admin user exists
  if auth_already_enabled; then
    info "Authorization is already enabled in mongod.conf."
    if admin_can_authenticate; then
      info "Admin user '${MONGO_ADMIN_USER}' exists and credentials are valid — skipping creation."
    else
      # Auth is on but credentials don't work — reset: disable auth, drop all
      # admin users, recreate with current env vars, re-enable auth.
      reset_admin_user
    fi
  else
    # No auth yet — create admin in no-auth mode
    if run_mongosh_file "
      var u = db.getSiblingDB('admin').getUser(\"$(js_escape "${MONGO_ADMIN_USER}")\");
      if (u !== null) { quit(0); } else { quit(1); }
    " &>/dev/null; then
      info "Admin user '${MONGO_ADMIN_USER}' already exists — skipping creation."
    else
      create_admin_user
    fi

    enable_auth
    info "Restarting mongod to activate authorization..."
    systemctl restart mongod
    wait_for_mongod
  fi

  # Phase 2: Create app user via authenticated admin connection
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
