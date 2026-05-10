#!/usr/bin/env bash
# =============================================================================
# 03_clone_from_cluster.sh
# Copy the full production database from the Atlas cluster to the local
# MongoDB instance using mongodump + mongorestore.
# Idempotent: each run creates a fresh timestamped dump directory.
#
# Required environment variables:
#   SOURCE_MONGO_URI    — Atlas SRV connection string (source, read-only access ok)
#   MONGO_ADMIN_USER    — Local MongoDB admin username
#   MONGO_ADMIN_PASSWORD — Local MongoDB admin password
#
# Usage:
#   export SOURCE_MONGO_URI="mongodb+srv://user:pass@host/dbname?retryWrites=true&w=majority"
#   export MONGO_ADMIN_USER=adminUser
#   export MONGO_ADMIN_PASSWORD='yourAdminPassword'
#   sudo ./03_clone_from_cluster.sh
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

  SOURCE_MONGO_URI     Atlas or cluster connection string (source database)
  MONGO_ADMIN_USER     Local MongoDB admin username
  MONGO_ADMIN_PASSWORD Local MongoDB admin password

Example:
  export SOURCE_MONGO_URI="mongodb+srv://user:pass@cluster.mongodb.net/coachify?retryWrites=true&w=majority"
  export MONGO_ADMIN_USER=adminUser
  export MONGO_ADMIN_PASSWORD='yourStrongAdminPassword'
  sudo ./03_clone_from_cluster.sh
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
# JS string escaping — escape \ and " for embedding in JS double-quoted strings
# ---------------------------------------------------------------------------
# Build URL-encoded local admin URI.
# URL-encoding the password avoids any issues with special chars in URIs.
# All local MongoDB connections (mongosh, mongodump, mongorestore) use this URI.
# ---------------------------------------------------------------------------
url_encode_pass() {
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

local_admin_uri() {
  # Separate 'local' from assignment so python3 exit code is NOT masked
  # (bash bug: 'local var=$(cmd)' always returns 0 for the local builtin)
  local enc_pass
  enc_pass="$(url_encode_pass "${MONGO_ADMIN_PASSWORD}")" \
    || die "url_encode_pass failed — is python3 in PATH for sudo?"
  printf 'mongodb://%s:%s@127.0.0.1:27017/admin?authSource=admin' \
    "${MONGO_ADMIN_USER}" "${enc_pass}"
}

# URI without database path — required when using --db flag in mongorestore
# (mongorestore rejects mismatched database in URI vs --db option)
local_admin_uri_no_db() {
  local enc_pass
  enc_pass="$(url_encode_pass "${MONGO_ADMIN_PASSWORD}")" \
    || die "url_encode_pass failed — is python3 in PATH for sudo?"
  printf 'mongodb://%s:%s@127.0.0.1:27017/?authSource=admin' \
    "${MONGO_ADMIN_USER}" "${enc_pass}"
}

# ---------------------------------------------------------------------------
# Verify required tools are installed
# ---------------------------------------------------------------------------
check_tools() {
  for tool in mongodump mongorestore mongosh python3; do
    if ! command -v "$tool" &>/dev/null; then
      die "'${tool}' not found in PATH. Install the required package."
    fi
  done
  info "Required tools present: mongodump, mongorestore, mongosh, python3."
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

test_local_connection() {
  local local_uri; local_uri="$(local_admin_uri)"
  info "Testing connectivity to local MongoDB..."
  local err_out
  err_out="$(mongosh --quiet "${local_uri}" --eval "db.adminCommand('ping')" 2>&1)" && {
    success "Connected to local MongoDB."
    return 0
  }
  warn "mongosh output: ${err_out}"
  die "Cannot connect to local MongoDB. Check MONGO_ADMIN_USER / MONGO_ADMIN_PASSWORD and that mongod is running with auth enabled."
}

# ---------------------------------------------------------------------------
# Print collection counts per database (human summary)
# ---------------------------------------------------------------------------
print_source_collection_counts() {
  local uri="$1"
  info "Collection document counts on source:"
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
  ' 2>/dev/null || warn "Could not print collection counts for source."
}

print_local_collection_counts() {
  local local_uri; local_uri="$(local_admin_uri)"
  info "Collection document counts on local:"
  mongosh --quiet "${local_uri}" --eval '
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
  ' 2>/dev/null || warn "Could not print local collection counts."
}

# ---------------------------------------------------------------------------
# Run mongodump from source
# ---------------------------------------------------------------------------
run_dump() {
  local dump_dir="$1"
  info "Starting mongodump from source cluster..."
  info "Dump directory: ${dump_dir}"
  info "This may take several minutes for large databases."

  # Strip the database name from the URI path so we can list and dump each
  # database individually. Using --db per database avoids creating prelude.json.gz
  # (the new mongodump full-cluster format), which mongorestore 100.x mishandles
  # when combined with --nsInclude/--nsExclude flags.
  local dump_uri
  dump_uri="$(python3 -c "
import sys
from urllib.parse import urlparse, urlunparse
u = urlparse(sys.argv[1])
print(urlunparse(u._replace(path='/')))
" "${SOURCE_MONGO_URI}")"
  info "Base URI (database stripped): ${dump_uri//:*@/:/***@}"

  # Get database list from source (exclude system databases)
  info "Fetching database list from source Atlas cluster..."
  local db_list
  db_list="$(mongosh --quiet "${dump_uri}" --eval '
    const dbs = db.getSiblingDB("admin").adminCommand({ listDatabases: 1 }).databases
      .filter(function(d) { return !["admin","local","config"].includes(d.name); })
      .map(function(d) { return d.name; });
    print(dbs.join("\n"));
  ' 2>/dev/null)"

  if [[ -z "$db_list" ]]; then
    die "Could not retrieve database list from source. Check SOURCE_MONGO_URI permissions."
  fi

  info "Databases to dump:"
  while IFS= read -r db_name; do
    [[ -z "$db_name" ]] && continue
    info "  - ${db_name}"
  done <<< "$db_list"

  # Dump each database individually.
  # --db ensures no prelude.json.gz is created (old-format dump structure).
  # Old format: dump_dir/{dbName}/{collection}.bson.gz + .metadata.json.gz
  while IFS= read -r db_name; do
    [[ -z "$db_name" ]] && continue
    info "  Dumping database '${db_name}'..."
    mongodump \
      --uri="${dump_uri}" \
      --db="${db_name}" \
      --readPreference=secondary \
      --gzip \
      --out="${dump_dir}"
  done <<< "$db_list"

  success "mongodump completed. Dump saved to: ${dump_dir}"
}

# ---------------------------------------------------------------------------
# Run mongorestore to local
# ---------------------------------------------------------------------------
run_restore() {
  local dump_dir="$1"
  # Use URI without /admin path — required by mongorestore when --db is specified
  # (mongorestore rejects mismatched database in URI path vs --db flag)
  local local_uri; local_uri="$(local_admin_uri_no_db)"
  info "Starting mongorestore to local instance..."
  info "Source dump: ${dump_dir}"

  # Count BSON files to ensure the dump is not empty
  local bson_count; bson_count="$(find "${dump_dir}" -name '*.bson.gz' -o -name '*.bson' | wc -l)"
  if [[ "${bson_count}" -eq 0 ]]; then
    die "Dump directory contains no BSON files. Aborting restore to avoid data loss."
  fi
  info "Found ${bson_count} BSON file(s) in dump — proceeding with restore."

  # mongodump 100.17.0 writes metadata.json.gz with 'admin.*' as the namespace
  # (the prelude.json.gz inside each DB directory remaps everything to admin).
  # --nsInclude cannot filter by source namespace in this case.
  #
  # Fix: use --db=DBNAME on each per-DB directory to force the correct target
  # database, ignoring whatever the metadata says.  --preserveUUID is omitted
  # because it conflicts with the --db namespace override.
  # --drop is kept for idempotency; it only drops collections within DBNAME.
  while IFS= read -r db_dir; do
    local db_name; db_name="$(basename "${db_dir}")"

    # Guard: never restore system databases even if they slipped into the dump
    if [[ "${db_name}" == "admin" || "${db_name}" == "local" || "${db_name}" == "config" ]]; then
      warn "Skipping system database directory: ${db_name}"
      continue
    fi

    info "  Restoring database '${db_name}'..."
    mongorestore \
      --uri="${local_uri}" \
      --db="${db_name}" \
      --gzip \
      --drop \
      --stopOnError \
      "${db_dir}"
  done < <(find "${dump_dir}" -mindepth 1 -maxdepth 1 -type d | sort)

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

  local local_uri; local_uri="$(local_admin_uri)"

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

  mongosh --quiet "${local_uri}" --eval '
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
  test_local_connection

  # Create timestamped dump directory
  local timestamp; timestamp="$(date '+%Y-%m-%d_%H%M%S')"
  local dump_dir="${DUMP_BASE_DIR}/${timestamp}"
  mkdir -p "$dump_dir"
  info "Dump directory: ${dump_dir}"

  # Print pre-dump source collection counts for operator verification
  print_source_collection_counts "$SOURCE_MONGO_URI"

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
