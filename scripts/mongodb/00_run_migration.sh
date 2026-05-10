#!/usr/bin/env bash
# =============================================================================
# 00_run_migration.sh
# Orchestrator: copy MongoDB scripts to the VPS via SCP, then run steps
# 01 → 02 → 03 → 04 remotely via SSH.
#
# STOPS before 05_cutover.sh — that step is intentionally manual.
# Run 05_cutover.sh only after you have inspected the verify report.
#
# Required environment variables (set on the machine running THIS script):
#   SOURCE_MONGO_URI      Atlas SRV connection string (used by steps 03 & 04)
#   MONGO_ADMIN_USER      Admin username to create on local instance
#   MONGO_ADMIN_PASSWORD  Admin password
#   MONGO_APP_USER        App username (readWrite, used in final MONGODB_URI)
#   MONGO_APP_PASSWORD    App password
#   MONGO_APP_DB          Database name (e.g. coachify)
#
# Optional overrides:
#   VPS_HOST              VPS IP or hostname  (default: 54.37.225.78)
#   VPS_USER              SSH user            (default: deploy)
#   SSH_KEY               Path to SSH key     (default: ~/.ssh/coachify_vps)
#   REMOTE_DIR            Remote scripts dir  (default: /home/deploy/production/coachify/scripts/mongodb)
#
# Usage:
#   export SOURCE_MONGO_URI="mongodb+srv://user:pass@host/coachify?retryWrites=true&w=majority"
#   export MONGO_ADMIN_USER=adminUser
#   export MONGO_ADMIN_PASSWORD='str0ng!Admin#Pass'
#   export MONGO_APP_USER=coachifyApp
#   export MONGO_APP_PASSWORD='str0ng!App#Pass'
#   export MONGO_APP_DB=coachify
#   ./00_run_migration.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via env)
# ---------------------------------------------------------------------------
VPS_HOST="${VPS_HOST:-54.37.225.78}"
VPS_USER="${VPS_USER:-deploy}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/coachify_vps}"
REMOTE_DIR="${REMOTE_DIR:-/home/deploy/production/coachify/scripts/mongodb}"
LOGFILE="./migration-$(date '+%Y%m%d_%H%M%S').log"

LOCAL_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
# URL-encode a string for safe embedding in MongoDB URIs.
# Encodes everything except unreserved URI characters (RFC 3986).
# Pure bash — no Python or external tools required.
# ---------------------------------------------------------------------------
url_encode() {
  local LC_ALL=C
  local str="$1"
  local encoded=""
  local i c
  for (( i=0; i<${#str}; i++ )); do
    c="${str:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) encoded+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; encoded+="$c" ;;
    esac
  done
  printf '%s' "$encoded"
}

# ---------------------------------------------------------------------------
# SSH / SCP helpers — always use the key, never fallback to other identities
# ---------------------------------------------------------------------------

# Used for SCP (no TTY needed, BatchMode safe)
SSH_OPTS=(-i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes)

# Used for remote execution: -tt forces a pseudo-TTY so sudo can prompt for
# a password interactively. BatchMode is intentionally omitted here.
SSH_EXEC_OPTS=(-tt -i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new)

remote() {
  # Run a command on the VPS via SSH with a pseudo-TTY (required for sudo)
  ssh "${SSH_EXEC_OPTS[@]}" "${VPS_USER}@${VPS_HOST}" "$@"
}

remote_with_env() {
  # Run a remote sudo command with migration env vars inlined in the command.
  # Uses -tt so sudo can prompt for password if not configured as NOPASSWD.
  local cmd="$1"
  ssh "${SSH_EXEC_OPTS[@]}" \
    "${VPS_USER}@${VPS_HOST}" \
    "export SOURCE_MONGO_URI=$(printf '%q' "${SOURCE_MONGO_URI}"); \
     export LOCAL_MONGO_URI=$(printf '%q' "${LOCAL_MONGO_URI}"); \
     export MONGO_ADMIN_USER=$(printf '%q' "${MONGO_ADMIN_USER}"); \
     export MONGO_ADMIN_PASSWORD=$(printf '%q' "${MONGO_ADMIN_PASSWORD}"); \
     export MONGO_APP_USER=$(printf '%q' "${MONGO_APP_USER}"); \
     export MONGO_APP_PASSWORD=$(printf '%q' "${MONGO_APP_PASSWORD}"); \
     export MONGO_APP_DB=$(printf '%q' "${MONGO_APP_DB}"); \
     ${cmd}"
}

copy_scripts() {
  info "Copying migration scripts to ${VPS_USER}@${VPS_HOST}:${REMOTE_DIR}..."

  # Ensure the remote directory exists (no sudo needed)
  ssh "${SSH_OPTS[@]}" "${VPS_USER}@${VPS_HOST}" "mkdir -p ${REMOTE_DIR}"

  # Copy all 5 scripts (SCP uses non-TTY opts)
  scp "${SSH_OPTS[@]}" \
    "${LOCAL_SCRIPTS_DIR}/01_install_mongodb.sh" \
    "${LOCAL_SCRIPTS_DIR}/02_create_admin_user.sh" \
    "${LOCAL_SCRIPTS_DIR}/03_clone_from_cluster.sh" \
    "${LOCAL_SCRIPTS_DIR}/04_verify_restore.sh" \
    "${LOCAL_SCRIPTS_DIR}/05_cutover.sh" \
    "${VPS_USER}@${VPS_HOST}:${REMOTE_DIR}/"

  # Ensure executable bit is set on the remote side (no sudo needed)
  ssh "${SSH_OPTS[@]}" "${VPS_USER}@${VPS_HOST}" "chmod +x ${REMOTE_DIR}/*.sh"

  success "Scripts copied and marked executable on VPS."
}

# ---------------------------------------------------------------------------
# Usage / validation
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<'EOF'
Required environment variables:
  SOURCE_MONGO_URI      Atlas SRV URI (source cluster)
  MONGO_ADMIN_USER      Admin username to create on local MongoDB
  MONGO_ADMIN_PASSWORD  Admin password
  MONGO_APP_USER        App username (readWrite on MONGO_APP_DB)
  MONGO_APP_PASSWORD    App password
  MONGO_APP_DB          Database name (e.g. coachify)

Optional:
  VPS_HOST              VPS IP or hostname  (default: 54.37.225.78)
  VPS_USER              SSH user            (default: deploy)
  SSH_KEY               Path to private key (default: ~/.ssh/coachify_vps)
  REMOTE_DIR            Remote scripts dir  (default: /home/deploy/production/coachify/scripts/mongodb)
EOF
  exit 1
}

validate_env() {
  local missing=0
  for var in SOURCE_MONGO_URI MONGO_ADMIN_USER MONGO_ADMIN_PASSWORD \
             MONGO_APP_USER MONGO_APP_PASSWORD MONGO_APP_DB; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: Required env var '${var}' is not set." >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || usage

  if [[ ! -f "$SSH_KEY" ]]; then
    die "SSH key not found: ${SSH_KEY}. Set SSH_KEY env var or place the key at the default path."
  fi

  # Build LOCAL_MONGO_URI with URL-encoded credentials so passwords containing
  # special characters (@ # : / ? ! +) don't break the MongoDB URI parser.
  local encoded_admin_user; encoded_admin_user=$(url_encode "${MONGO_ADMIN_USER}")
  local encoded_admin_pass; encoded_admin_pass=$(url_encode "${MONGO_ADMIN_PASSWORD}")
  LOCAL_MONGO_URI="mongodb://${encoded_admin_user}:${encoded_admin_pass}@localhost:27017/admin?authSource=admin"
  export LOCAL_MONGO_URI
}

check_tools() {
  for tool in ssh scp; do
    command -v "$tool" &>/dev/null || die "'${tool}' not found in PATH."
  done
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
step_01_install() {
  info "━━━ STEP 1 ─ Install MongoDB 6.0 on VPS ━━━"
  remote "sudo bash ${REMOTE_DIR}/01_install_mongodb.sh"
  success "Step 1 complete."
}

step_02_create_users() {
  info "━━━ STEP 2 ─ Bootstrap MongoDB authentication ━━━"
  remote_with_env "sudo --preserve-env=SOURCE_MONGO_URI,LOCAL_MONGO_URI,MONGO_ADMIN_USER,MONGO_ADMIN_PASSWORD,MONGO_APP_USER,MONGO_APP_PASSWORD,MONGO_APP_DB \
    bash ${REMOTE_DIR}/02_create_admin_user.sh"
  success "Step 2 complete."
}

step_03_clone() {
  info "━━━ STEP 3 ─ Clone Atlas → local (mongodump + mongorestore) ━━━"
  info "This may take several minutes for large databases."
  remote_with_env "cd ${REMOTE_DIR} && bash ${REMOTE_DIR}/03_clone_from_cluster.sh"
  success "Step 3 complete."
}

step_04_verify() {
  info "━━━ STEP 4 ─ Verify restore integrity ━━━"
  remote_with_env "cd ${REMOTE_DIR} && bash ${REMOTE_DIR}/04_verify_restore.sh"
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    success "Step 4 complete — all collections match."
  else
    warn "Step 4: verification found discrepancies. Review the report above."
    warn "Do NOT run cutover until discrepancies are resolved."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "========================================="
  info " Coachify MongoDB Migration"
  info " VPS : ${VPS_USER}@${VPS_HOST}"
  info " Key : ${SSH_KEY}"
  info " Log : ${LOGFILE}"
  info "========================================="

  validate_env
  check_tools

  # Test SSH connectivity before doing anything (use non-TTY opts for quick check)
  info "Testing SSH connectivity to VPS..."
  ssh "${SSH_OPTS[@]}" "${VPS_USER}@${VPS_HOST}" "echo 'SSH OK'" || die "Cannot connect to ${VPS_USER}@${VPS_HOST} with key ${SSH_KEY}."
  success "SSH connection established."

  copy_scripts
  step_01_install
  step_02_create_users
  step_03_clone
  step_04_verify

  info ""
  info "========================================="
  success "Migration complete — database is on the local VPS instance."
  info ""
  info "  Local URI (app user) :"
  info "  mongodb://${MONGO_APP_USER}:***@localhost:27017/${MONGO_APP_DB}?authSource=${MONGO_APP_DB}"
  info ""
  info "  ┌──────────────────────────────────────────────────────────┐"
  info "  │  CUTOVER IS NOT YET DONE — services still point to Atlas │"
  info "  │                                                          │"
  info "  │  When you are ready to switch traffic:                   │"
  info "  │                                                          │"
  info "  │  export NEW_MONGO_URI=\"mongodb://${MONGO_APP_USER}:PASS@localhost:27017/${MONGO_APP_DB}?authSource=${MONGO_APP_DB}\""
  info "  │                                                          │"
  info "  │  Then run ON THE VPS:                                    │"
  info "  │    sudo bash ${REMOTE_DIR}/05_cutover.sh  │"
  info "  │                                                          │"
  info "  │  Or SSH in and run it interactively:                     │"
  info "  │    ssh -i ${SSH_KEY} -o IdentitiesOnly=yes ${VPS_USER}@${VPS_HOST}  │"
  info "  └──────────────────────────────────────────────────────────┘"
  info "========================================="
}

main "$@"
