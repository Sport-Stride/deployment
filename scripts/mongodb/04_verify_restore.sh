#!/usr/bin/env bash
# =============================================================================
# 04_verify_restore.sh
# Standalone restore integrity verification — runs independently of 03.
# Compares document counts, index counts, and index definitions between
# the source cluster and the local MongoDB instance.
#
# Exit codes:
#   0 — all collections and indexes match (safe to proceed with cutover)
#   1 — at least one mismatch found (do NOT cut over until resolved)
#
# Required environment variables:
#   SOURCE_MONGO_URI     — Atlas or cluster connection string (source)
#   MONGO_ADMIN_USER     — Local MongoDB admin username
#   MONGO_ADMIN_PASSWORD — Local MongoDB admin password
#
# Usage:
#   export SOURCE_MONGO_URI="mongodb+srv://user:pass@host/db?retryWrites=true&w=majority"
#   export MONGO_ADMIN_USER=adminUser
#   export MONGO_ADMIN_PASSWORD='yourAdminPassword'
#   sudo ./04_verify_restore.sh
#   echo "Exit code: $?"
# =============================================================================
set -euo pipefail

LOGFILE="./mongodb-verify.log"
TMP_SOURCE="/tmp/mongo_verify_source.json"
TMP_LOCAL="/tmp/mongo_verify_local.json"

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
Usage: set the following environment variables before running this script:

  SOURCE_MONGO_URI     Atlas or cluster connection string (source database)
  MONGO_ADMIN_USER     Local MongoDB admin username
  MONGO_ADMIN_PASSWORD Local MongoDB admin password

Example:
  export SOURCE_MONGO_URI="mongodb+srv://user:pass@cluster.mongodb.net/coachify?retryWrites=true&w=majority"
  export MONGO_ADMIN_USER=adminUser
  export MONGO_ADMIN_PASSWORD='yourAdminPassword'
  sudo ./04_verify_restore.sh
EOF
  exit 1
}

validate_env() {
  local missing=0
  for var in SOURCE_MONGO_URI MONGO_ADMIN_USER MONGO_ADMIN_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: Required env var '${var}' is not set." >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || usage
}

# ---------------------------------------------------------------------------
# Build URL-encoded local admin URI (avoids URI parse errors with special chars)
# ---------------------------------------------------------------------------
url_encode_pass() {
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

local_admin_uri() {
  local enc_pass
  enc_pass="$(url_encode_pass "${MONGO_ADMIN_PASSWORD}")" \
    || die "url_encode_pass failed — is python3 in PATH for sudo?"
  printf 'mongodb://%s:%s@127.0.0.1:27017/admin?authSource=admin' \
    "${MONGO_ADMIN_USER}" "${enc_pass}"
}

# ---------------------------------------------------------------------------
# Verify required tools
# ---------------------------------------------------------------------------
check_tools() {
  for tool in mongosh python3; do
    if ! command -v "$tool" &>/dev/null; then
      die "'${tool}' not found in PATH."
    fi
  done
}

# ---------------------------------------------------------------------------
# Test connectivity
# ---------------------------------------------------------------------------
test_connection() {
  local label="$1"
  local uri="$2"
  info "Testing connectivity to ${label}..."
  if ! mongosh --quiet "$uri" --eval "db.adminCommand('ping')" &>/dev/null; then
    die "Cannot connect to ${label}. Check URI and network."
  fi
  success "Connected to ${label}."
}

# ---------------------------------------------------------------------------
# Collect full metadata (counts + indexes) from a URI into a JSON file
# ---------------------------------------------------------------------------
collect_metadata() {
  local label="$1"
  local uri="$2"
  local outfile="$3"

  info "Collecting metadata from ${label}..."

  mongosh --quiet "$uri" --eval '
    const adminDb = db.getSiblingDB("admin");
    const allDbs = adminDb.adminCommand({ listDatabases: 1 }).databases
      .filter(function(d) {
        return !["admin", "local", "config"].includes(d.name);
      });

    const result = {};

    allDbs.forEach(function(dbInfo) {
      const targetDb = adminDb.getSiblingDB(dbInfo.name);
      const collections = targetDb.getCollectionNames();
      result[dbInfo.name] = {};

      collections.forEach(function(col) {
        const coll = targetDb.getCollection(col);

        // Document count
        const docCount = coll.countDocuments();

        // Index information
        const rawIndexes = coll.getIndexes();
        const indexCount = rawIndexes.length;

        // Normalize index definitions: sort by name for stable comparison
        const indexDefs = rawIndexes
          .sort(function(a, b) { return a.name < b.name ? -1 : 1; })
          .map(function(idx) {
            return {
              name: idx.name,
              key:  idx.key,
              unique: idx.unique || false,
              sparse: idx.sparse || false
            };
          });

        result[dbInfo.name][col] = {
          count:    docCount,
          idxCount: indexCount,
          indexes:  indexDefs
        };
      });
    });

    print(JSON.stringify(result));
  ' 2>/dev/null > "$outfile" || die "Failed to collect metadata from ${label}."

  success "Metadata collected from ${label} → ${outfile}"
}

# ---------------------------------------------------------------------------
# Compare and print structured report
# ---------------------------------------------------------------------------
run_comparison() {
  local source_file="$1"
  local local_file="$2"

  python3 - <<'PYEOF'
import json, sys

def load(path):
    with open(path) as f:
        return json.load(f)

source = load("/tmp/mongo_verify_source.json")
local  = load("/tmp/mongo_verify_local.json")

all_pass = True
rows = []

# Check all source dbs/collections against local
for db_name, collections in source.items():
    for col, src_info in sorted(collections.items()):
        local_db   = local.get(db_name, {})
        local_info = local_db.get(col)

        if local_info is None:
            rows.append({
                "db":        db_name,
                "col":       col,
                "src_count": src_info["count"],
                "loc_count": "MISSING",
                "delta":     "N/A",
                "src_idx":   src_info["idxCount"],
                "loc_idx":   "N/A",
                "status":    "FAIL — collection missing in local",
            })
            all_pass = False
            continue

        src_count = src_info["count"]
        loc_count = local_info["count"]
        delta     = loc_count - src_count
        src_idx   = src_info["idxCount"]
        loc_idx   = local_info["idxCount"]

        # Index definition comparison
        src_idx_names = sorted([i["name"] for i in src_info["indexes"]])
        loc_idx_names = sorted([i["name"] for i in local_info["indexes"]])
        idx_match = src_idx_names == loc_idx_names

        issues = []
        if delta != 0:
            issues.append(f"count delta {delta:+d}")
            all_pass = False
        if not idx_match:
            missing_idx  = set(src_idx_names) - set(loc_idx_names)
            extra_idx    = set(loc_idx_names) - set(src_idx_names)
            if missing_idx:
                issues.append(f"indexes missing: {sorted(missing_idx)}")
            if extra_idx:
                issues.append(f"extra indexes: {sorted(extra_idx)}")
            all_pass = False

        status = "PASS" if not issues else "FAIL — " + "; ".join(issues)

        rows.append({
            "db":        db_name,
            "col":       col,
            "src_count": src_count,
            "loc_count": loc_count,
            "delta":     f"{delta:+d}" if delta != 0 else "0",
            "src_idx":   src_idx,
            "loc_idx":   loc_idx,
            "status":    status,
        })

# Check for collections in local that don't exist in source
for db_name, collections in local.items():
    if db_name in ["admin", "local", "config"]:
        continue
    for col in sorted(collections.keys()):
        if db_name not in source or col not in source[db_name]:
            rows.append({
                "db":        db_name,
                "col":       col,
                "src_count": "N/A",
                "loc_count": local[db_name][col]["count"],
                "delta":     "N/A",
                "src_idx":   "N/A",
                "loc_idx":   local[db_name][col]["idxCount"],
                "status":    "WARN — exists in local but not in source",
            })

# Print structured table
print("")
print(f"{'DATABASE':<20} {'COLLECTION':<30} {'SRC_DOCS':>9} {'LOC_DOCS':>9} {'DELTA':>7} {'SRC_IDX':>7} {'LOC_IDX':>7}  STATUS")
print("-" * 115)
for r in rows:
    print(
        f"{r['db']:<20} {r['col']:<30} "
        f"{str(r['src_count']):>9} {str(r['loc_count']):>9} {str(r['delta']):>7} "
        f"{str(r['src_idx']):>7} {str(r['loc_idx']):>7}  {r['status']}"
    )
print("-" * 115)
print("")

if all_pass:
    print("RESULT: PASS — all collections and indexes match. Safe to proceed with 05_cutover.sh.")
    sys.exit(0)
else:
    print("RESULT: FAIL — one or more mismatches detected. Do NOT cut over until resolved.")
    sys.exit(1)
PYEOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "========================================="
  info " MongoDB Restore Verification"
  info "========================================="

  validate_env
  check_tools

  local local_uri; local_uri="$(local_admin_uri)"

  test_connection "source (Atlas/cluster)" "$SOURCE_MONGO_URI"
  test_connection "local MongoDB" "${local_uri}"

  collect_metadata "source" "$SOURCE_MONGO_URI" "$TMP_SOURCE"
  collect_metadata "local"  "${local_uri}"       "$TMP_LOCAL"

  info "Running comparison..."
  run_comparison "$TMP_SOURCE" "$TMP_LOCAL"
  local exit_code=$?

  # Cleanup temp files
  rm -f "$TMP_SOURCE" "$TMP_LOCAL"

  info "========================================="
  if [[ $exit_code -eq 0 ]]; then
    success "Verification passed. Proceed with 05_cutover.sh."
  else
    warn "Verification failed. Resolve issues before running 05_cutover.sh."
    warn "Common fixes:"
    warn "  - Count delta: re-run 03_clone_from_cluster.sh (data may have been written during dump)"
    warn "  - Missing index: mongorestore restores indexes; check if mongorestore completed cleanly"
    warn "  - Large count delta: consider --oplog / --oplogReplay for point-in-time consistency"
  fi
  info "========================================="

  return $exit_code
}

main "$@"
