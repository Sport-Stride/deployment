#!/usr/bin/env bash
# =============================================================================
# 03_clone_from_cluster.sh
# Copy the full production database from the Atlas cluster to the local
# MongoDB instance using mongodump + mongorestore.
# Idempotent: each run creates a fresh timestamped dump directory.
#
# Required environment variables:
#   SOURCE_MONGO_URI   — Atlas SRV connection string (source, read-only access ok)
#   LOCAL_MONGO_URI    — Local MongoDB URI with admin credentials
#
# Usage:
#   export SOURCE_MONGO_URI="mongodb+srv://user:pass@host/dbname?retryWrites=true&w=majority"
#   export LOCAL_MONGO_URI="mongodb://adminUser:adminPass@localhost:27017/admin?authSource=admin"
#   ./03_clone_from_cluster.sh
#
# Best practices enforced:
#   - mongodump/mongorestore (not mongoexport/import) — preserves BSON types
#   - --readPreference=secondary on source — no load on Atlas primary
#   - --gzip — reduces dump size and transfer time
#   - --preserveUUID — keeps collection UUIDs consistent post-restore
#   - --drop on restore — replaces any existing partial data
#   - Dump directory is NEVER deleted automatically (rollback artifact)
#   - Document count comparison printed before finishing
# =============================================================================
set -euo pipefail

DUMP_BASE_DIR="./dumps"
LOGFILE="./mongodb-clone.log"

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

  SOURCE_MONGO_URI   Atlas or cluster connection string (source database)
  LOCAL_MONGO_URI    Local MongoDB connection string (destination, admin credentials)

Example:
  export SOURCE_MONGO_URI="mongodb+srv://user:pass@cluster.mongodb.net/coachify?retryWrites=true&w=majority"
  export LOCAL_MONGO_URI="mongodb://adminUser:adminPass@localhost:27017/admin?authSource=admin"
  ./03_clone_from_cluster.sh
EOF
  exit 1
}

validate_env() {
  local missing=0
  for var in SOURCE_MONGO_URI LOCAL_MONGO_URI; do
    if [[ -z "${!var:-}" ]]; then
      echo "ERROR: Required env var '${var}' is not set." >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || usage
}

# ---------------------------------------------------------------------------
# Verify required tools are installed
# ---------------------------------------------------------------------------
check_tools() {
  for tool in mongodump mongorestore mongosh; do
    if ! command -v "$tool" &>/dev/null; then
      die "'${tool}' not found in PATH. Install mongodb-database-tools package."
    fi
  done
  info "Required tools present: mongodump, mongorestore, mongosh."
}

# ---------------------------------------------------------------------------
# Test connectivity to a URI before committing to a long operation
# ---------------------------------------------------------------------------
test_connection() {
  local label="$1"
  local uri="$2"
  info "Testing connectivity to ${label}..."
  if ! mongosh --quiet "$uri" --eval "db.adminCommand('ping')" &>/dev/null; then
    die "Cannot connect to ${label}. Check the URI and network access."
  fi
  success "Connected to ${label}."
}

# ---------------------------------------------------------------------------
# Print collection counts per database from a given URI (human summary)
# ---------------------------------------------------------------------------
print_collection_counts() {
  local label="$1"
  local uri="$2"
  info "Collection document counts on ${label}:"
  mongosh --quiet "$uri" --eval '
    const adminDb = db.getSiblingDB("admin");
    const dbs = adminDb.adminCommand({ listDatabases: 1 }).databases
      .filter(d => !["admin","local","config"].includes(d.name));
    dbs.forEach(function(dbInfo) {
      const targetDb = adminDb.getSiblingDB(dbInfo.name);
      const collections = targetDb.getCollectionNames();
      collections.forEach(function(col) {
        const count = targetDb.getCollection(col).countDocuments();
        print("  " + dbInfo.name + "." + col + " => " + count + " documents");
      });
    });
  ' 2>/dev/null || warn "Could not print collection counts for ${label}."
}

# ---------------------------------------------------------------------------
# Run mongodump from source
# ---------------------------------------------------------------------------
run_dump() {
  local dump_dir="$1"
  info "Starting mongodump from source cluster..."
  info "Dump directory: ${dump_dir}"
  info "This may take several minutes for large databases."

  # --readPreference=secondary: read from secondary replica on Atlas, not primary
  # --gzip: compress output, reduces size and transfer time significantly
  # --forceTableScan: avoid stale oplog cursor issues on Atlas shared clusters
  mongodump \
    --uri="${SOURCE_MONGO_URI}" \
    --readPreference=secondary \
    --gzip \
    --out="${dump_dir}" \
    --excludeCollection=system.profile

  success "mongodump completed. Dump saved to: ${dump_dir}"
}

# ---------------------------------------------------------------------------
# Run mongorestore to local
# ---------------------------------------------------------------------------
run_restore() {
  local dump_dir="$1"
  info "Starting mongorestore to local instance..."
  info "Source dump: ${dump_dir}"
  info "--drop will replace any existing collections — this is expected for a clean clone."

  # --drop: drop each collection before restoring (ensures clean state)
  # --preserveUUID: keep original collection UUIDs (consistency across environments)
  # --gzip: matches the dump format
  # --stopOnError: fail immediately if any collection restore fails
  mongorestore \
    --uri="${LOCAL_MONGO_URI}" \
    --gzip \
    --drop \
    --preserveUUID \
    --stopOnError \
    "${dump_dir}"

  success "mongorestore completed."
}

# ---------------------------------------------------------------------------
# Compare document counts between source and destination
# ---------------------------------------------------------------------------
compare_counts() {
  local dump_dir="$1"
  info "Running post-restore document count comparison..."

  local report_file="${dump_dir}/restore-verification.txt"
  local all_pass=true

  mongosh --quiet "$SOURCE_MONGO_URI" --eval '
    const adminDb = db.getSiblingDB("admin");
    const dbs = adminDb.adminCommand({ listDatabases: 1 }).databases
      .filter(d => !["admin","local","config"].includes(d.name));
    const result = {};
    dbs.forEach(function(dbInfo) {
      const targetDb = adminDb.getSiblingDB(dbInfo.name);
      const collections = targetDb.getCollectionNames();
      result[dbInfo.name] = {};
      collections.forEach(function(col) {
        result[dbInfo.name][col] = targetDb.getCollection(col).countDocuments();
      });
    });
    print(JSON.stringify(result));
  ' 2>/dev/null > /tmp/mongo_source_counts.json || die "Failed to read source counts."

  mongosh --quiet "$LOCAL_MONGO_URI" --eval '
    const adminDb = db.getSiblingDB("admin");
    const dbs = adminDb.adminCommand({ listDatabases: 1 }).databases
      .filter(d => !["admin","local","config"].includes(d.name));
    const result = {};
    dbs.forEach(function(dbInfo) {
      const targetDb = adminDb.getSiblingDB(dbInfo.name);
      const collections = targetDb.getCollectionNames();
      result[dbInfo.name] = {};
      collections.forEach(function(col) {
        result[dbInfo.name][col] = targetDb.getCollection(col).countDocuments();
      });
    });
    print(JSON.stringify(result));
  ' 2>/dev/null > /tmp/mongo_local_counts.json || die "Failed to read local counts."

  # Print comparison table using Python (available on any modern Linux)
  python3 - <<'PYEOF' | tee "$report_file"
import json, sys

with open("/tmp/mongo_source_counts.json") as f:
    source = json.load(f)
with open("/tmp/mongo_local_counts.json") as f:
    local  = json.load(f)

print("")
print(f"{'DATABASE':<25} {'COLLECTION':<35} {'SOURCE':>10} {'LOCAL':>10} {'DELTA':>8}  STATUS")
print("-" * 100)

all_pass = True
for db_name, collections in source.items():
    for col, src_count in sorted(collections.items()):
        local_count = local.get(db_name, {}).get(col, "MISSING")
        if local_count == "MISSING":
            delta = "N/A"
            status = "FAIL — collection missing in local"
            all_pass = False
        else:
            delta = local_count - src_count
            status = "PASS" if delta == 0 else f"FAIL — delta {delta:+d}"
            if delta != 0:
                all_pass = False
        print(f"{db_name:<25} {col:<35} {src_count:>10} {str(local_count):>10} {str(delta):>8}  {status}")

print("-" * 100)
if all_pass:
    print("RESULT: ALL COLLECTIONS MATCH — restore verified successfully.")
    sys.exit(0)
else:
    print("RESULT: MISMATCH DETECTED — review FAILed rows above before cutover.")
    sys.exit(1)
PYEOF

  local py_exit=$?
  if [[ $py_exit -eq 0 ]]; then
    success "Restore verification passed. Full report saved to: ${report_file}"
    return 0
  else
    warn "Restore verification found discrepancies. Review: ${report_file}"
    warn "Do NOT run 05_cutover.sh until discrepancies are resolved."
    warn "You can re-run 04_verify_restore.sh at any time for a fresh check."
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  info "========================================="
  info " MongoDB Cluster Clone (dump + restore)"
  info "========================================="

  validate_env
  check_tools
  test_connection "source (Atlas/cluster)" "$SOURCE_MONGO_URI"
  test_connection "local MongoDB" "$LOCAL_MONGO_URI"

  # Create timestamped dump directory
  local timestamp; timestamp="$(date '+%Y-%m-%d_%H%M%S')"
  local dump_dir="${DUMP_BASE_DIR}/${timestamp}"
  mkdir -p "$dump_dir"
  info "Dump directory: ${dump_dir}"

  # Print pre-dump source collection counts for operator verification
  print_collection_counts "source (pre-dump)" "$SOURCE_MONGO_URI"

  # Dump
  run_dump "$dump_dir"

  # Print post-dump collection counts (confirms dump is complete before restore)
  info "Verifying dump directory structure..."
  find "$dump_dir" -name "*.bson.gz" | sort | while read -r f; do
    info "  Dumped: $(basename "$(dirname "$f")")/$(basename "$f")"
  done

  # Restore
  run_restore "$dump_dir"

  # Verify
  compare_counts "$dump_dir"
  local verify_result=$?

  info "========================================="
  info " Clone Summary"
  info "  Dump directory: ${dump_dir}"
  info "  IMPORTANT: Do NOT delete this directory."
  info "  Keep it as a rollback artifact for at least 24h after cutover."
  info ""
  if [[ $verify_result -eq 0 ]]; then
    success "Clone completed and verified. Safe to proceed with 05_cutover.sh."
  else
    warn "Clone completed but verification found discrepancies."
    warn "Run 04_verify_restore.sh for a detailed check before cutover."
  fi
  info "========================================="

  return $verify_result
}

main "$@"
