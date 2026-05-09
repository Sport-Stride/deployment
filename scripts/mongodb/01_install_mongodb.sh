#!/usr/bin/env bash
# =============================================================================
# 01_install_mongodb.sh
# Install MongoDB Community Edition 6.0 on the target server.
# Idempotent: safe to run more than once.
#
# Supports: Ubuntu 20.04/22.04/24.04, Debian 11/12, RHEL/CentOS/Rocky 8/9
# MongoDB version: 6.0 (matching MONGODB_VERSION in versions.env)
# =============================================================================
set -euo pipefail

MONGO_MAJOR="6.0"
MONGO_VERSION="6.0.15"   # Pin to a specific patch — change when upgrading
MONGOD_CONF="/etc/mongod.conf"
LOGFILE="/var/log/mongodb-install.log"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local level="$1"; shift
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] [${level}] $*" | tee -a "$LOGFILE"
}

info()    { log "INFO " "$@"; }
warn()    { log "WARN " "$@"; }
success() { log "OK   " "$@"; }
die()     { log "ERROR" "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Detect OS
# ---------------------------------------------------------------------------
detect_os() {
  if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found — cannot detect OS."
  fi
  # shellcheck source=/dev/null
  source /etc/os-release
  OS_ID="${ID}"
  OS_VERSION_ID="${VERSION_ID}"
  OS_CODENAME="${VERSION_CODENAME:-}"

  info "Detected OS: ${PRETTY_NAME:-${ID} ${VERSION_ID}}"

  case "${OS_ID}" in
    ubuntu|debian) OS_FAMILY="debian" ;;
    rhel|centos|rocky|almalinux|ol) OS_FAMILY="rhel" ;;
    *) die "Unsupported OS: ${OS_ID}. Supported: Ubuntu, Debian, RHEL, CentOS, Rocky, AlmaLinux." ;;
  esac

  info "OS family: ${OS_FAMILY}"
}

# ---------------------------------------------------------------------------
# Ulimits for the mongodb system user
# ---------------------------------------------------------------------------
configure_ulimits() {
  local limits_file="/etc/security/limits.d/99-mongodb.conf"
  if [[ -f "$limits_file" ]]; then
    info "Ulimits already configured at ${limits_file} — skipping."
    return
  fi
  info "Configuring ulimits for mongodb user..."
  cat > "$limits_file" <<'EOF'
# MongoDB production ulimits — per MongoDB Linux production notes
mongodb soft nofile 64000
mongodb hard nofile 64000
mongodb soft nproc  64000
mongodb hard nproc  64000
EOF
  success "Ulimits written to ${limits_file}."
}

# ---------------------------------------------------------------------------
# Install on Debian/Ubuntu
# ---------------------------------------------------------------------------
install_debian() {
  info "Installing prerequisites..."
  apt-get update -qq
  apt-get install -y --no-install-recommends \
    gnupg curl ca-certificates lsb-release

  # Determine the correct distro codename for MongoDB repo
  local distro_codename
  case "${OS_ID}" in
    ubuntu)
      case "${OS_VERSION_ID}" in
        20.04) distro_codename="focal"   ;;
        22.04) distro_codename="jammy"   ;;
        24.04) distro_codename="noble"   ;;
        *) die "Unsupported Ubuntu version: ${OS_VERSION_ID}. Supported: 20.04, 22.04, 24.04." ;;
      esac
      ;;
    debian)
      case "${OS_VERSION_ID}" in
        11) distro_codename="bullseye" ;;
        12) distro_codename="bookworm" ;;
        *) die "Unsupported Debian version: ${OS_VERSION_ID}. Supported: 11, 12." ;;
      esac
      ;;
  esac

  local keyring_path="/usr/share/keyrings/mongodb-server-${MONGO_MAJOR}.gpg"
  if [[ ! -f "$keyring_path" ]]; then
    info "Importing MongoDB GPG key from pgp.mongodb.com..."
    curl -fsSL "https://pgp.mongodb.com/server-${MONGO_MAJOR}.asc" \
      | gpg --dearmor -o "$keyring_path"
    success "GPG key imported."
  else
    info "MongoDB GPG key already present — skipping import."
  fi

  local list_file="/etc/apt/sources.list.d/mongodb-org-${MONGO_MAJOR}.list"
  if [[ ! -f "$list_file" ]]; then
    info "Adding MongoDB ${MONGO_MAJOR} apt repository for ${distro_codename}..."
    echo "deb [ arch=amd64,arm64 signed-by=${keyring_path} ] https://repo.mongodb.org/apt/${OS_ID} ${distro_codename}/mongodb-org/${MONGO_MAJOR} multiverse" \
      > "$list_file"
    success "Repository added."
  else
    info "MongoDB apt repository already configured — skipping."
  fi

  apt-get update -qq

  if dpkg -l mongodb-org 2>/dev/null | grep -q "^ii.*${MONGO_VERSION}"; then
    info "mongodb-org ${MONGO_VERSION} already installed — skipping."
  else
    info "Installing mongodb-org=${MONGO_VERSION}..."
    # Pin the version to prevent unintended upgrades
    apt-get install -y \
      "mongodb-org=${MONGO_VERSION}" \
      "mongodb-org-database=${MONGO_VERSION}" \
      "mongodb-org-server=${MONGO_VERSION}" \
      "mongodb-mongosh=${MONGO_VERSION}" \
      "mongodb-org-mongos=${MONGO_VERSION}" \
      "mongodb-org-tools=${MONGO_VERSION}"
    # Hold versions
    echo "mongodb-org hold"          | dpkg --set-selections
    echo "mongodb-org-database hold" | dpkg --set-selections
    echo "mongodb-org-server hold"   | dpkg --set-selections
    echo "mongodb-mongosh hold"      | dpkg --set-selections
    echo "mongodb-org-mongos hold"   | dpkg --set-selections
    echo "mongodb-org-tools hold"    | dpkg --set-selections
    success "mongodb-org ${MONGO_VERSION} installed and pinned."
  fi
}

# ---------------------------------------------------------------------------
# Install on RHEL/CentOS/Rocky
# ---------------------------------------------------------------------------
install_rhel() {
  local repo_file="/etc/yum.repos.d/mongodb-org-${MONGO_MAJOR}.repo"
  if [[ ! -f "$repo_file" ]]; then
    info "Adding MongoDB ${MONGO_MAJOR} yum repository..."
    cat > "$repo_file" <<EOF
[mongodb-org-${MONGO_MAJOR}]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/${MONGO_MAJOR}/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-${MONGO_MAJOR}.asc
EOF
    success "Yum repository added."
  else
    info "MongoDB yum repository already configured — skipping."
  fi

  if rpm -q "mongodb-org-${MONGO_VERSION}" &>/dev/null; then
    info "mongodb-org-${MONGO_VERSION} already installed — skipping."
  else
    info "Installing mongodb-org-${MONGO_VERSION}..."
    # Use dnf if available, else yum
    local pkg_mgr="yum"
    command -v dnf &>/dev/null && pkg_mgr="dnf"
    "${pkg_mgr}" install -y "mongodb-org-${MONGO_VERSION}"
    success "mongodb-org ${MONGO_VERSION} installed."
  fi
}

# ---------------------------------------------------------------------------
# Calculate WiredTiger cache (50% of RAM, floor 256 MB)
# ---------------------------------------------------------------------------
calculate_wt_cache() {
  local total_kb
  total_kb="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
  local total_mb=$(( total_kb / 1024 ))
  local cache_mb=$(( total_mb / 2 ))
  if (( cache_mb < 256 )); then cache_mb=256; fi
  # MongoDB expects GB, expressed as float with one decimal
  echo "scale=1; ${cache_mb}/1024" | bc
}

# ---------------------------------------------------------------------------
# Write hardened mongod.conf
# ---------------------------------------------------------------------------
write_mongod_conf() {
  if [[ -f "${MONGOD_CONF}.pre-install-bak" ]]; then
    info "mongod.conf backup already exists — skipping overwrite."
    return
  fi

  info "Writing hardened mongod.conf..."

  # Back up the default config if present
  if [[ -f "$MONGOD_CONF" ]]; then
    cp "$MONGOD_CONF" "${MONGOD_CONF}.pre-install-bak"
    info "Original config backed up to ${MONGOD_CONF}.pre-install-bak"
  fi

  local wt_cache; wt_cache="$(calculate_wt_cache)"
  info "WiredTiger cache set to ${wt_cache} GB (50% of available RAM)."

  cat > "$MONGOD_CONF" <<EOF
# /etc/mongod.conf — MongoDB ${MONGO_MAJOR} production configuration
# Generated by 01_install_mongodb.sh on $(date '+%Y-%m-%d %H:%M:%S')

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
  logRotate: reopen          # Enable log rotation via SIGUSR1 / logrotate

storage:
  dbPath: /var/lib/mongodb
  journal:
    enabled: true            # Always enable journaling for crash safety
  wiredTiger:
    engineConfig:
      cacheSizeGB: ${wt_cache}  # 50% of RAM — explicit to avoid MongoDB default (60% of RAM - 1GB)

net:
  port: 27017
  bindIp: 127.0.0.1          # Never expose to public internet; microservices on same host use localhost

# Authentication is disabled on first boot so 02_create_admin_user.sh can bootstrap.
# After running 02_create_admin_user.sh this will be changed to:
#   security:
#     authorization: enabled
security:
  authorization: disabled

processManagement:
  timeZoneInfo: /usr/share/zoneinfo
EOF

  success "mongod.conf written."
}

# ---------------------------------------------------------------------------
# Enable and start mongod
# ---------------------------------------------------------------------------
enable_mongod() {
  info "Enabling mongod to start on boot..."
  systemctl enable mongod
  success "mongod enabled."

  if systemctl is-active --quiet mongod; then
    info "mongod is already running."
  else
    info "Starting mongod..."
    systemctl start mongod
    success "mongod started."
  fi
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
verify_install() {
  info "Verifying installation..."
  local installed_version
  installed_version="$(mongod --version | head -1)"
  info "Installed: ${installed_version}"

  local status
  status="$(systemctl is-active mongod)"
  if [[ "$status" == "active" ]]; then
    success "mongod is running (systemctl status: active)."
  else
    die "mongod is NOT running (status: ${status}). Check: journalctl -xeu mongod"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "This script must be run as root (or via sudo)."
  fi

  info "========================================="
  info " MongoDB ${MONGO_MAJOR} Install Script"
  info "========================================="

  detect_os
  configure_ulimits

  case "${OS_FAMILY}" in
    debian) install_debian ;;
    rhel)   install_rhel   ;;
  esac

  write_mongod_conf
  enable_mongod

  # Reload config in case mongod was already running with the old config
  info "Reloading mongod with new config..."
  systemctl restart mongod

  verify_install

  info "========================================="
  success "MongoDB ${MONGO_MAJOR} installed and running."
  info "Next step: run 02_create_admin_user.sh to bootstrap authentication."
  info "========================================="
}

main "$@"
