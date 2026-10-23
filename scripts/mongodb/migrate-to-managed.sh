#!/usr/bin/env bash
# =============================================================================
# migrate-to-managed.sh - copy the LOCAL MongoDB (coachify-mongodb) to the
# MANAGED cluster (Atlas). Run ON THE PRODUCTION SERVER. Never touches the
# local data (read-only on the source); only the target is written.
#
#   --dry-run    read-only: config checks, preflight, db sizes, time estimate,
#                the exact plan. Writes nothing anywhere.
#   --rehearsal  copy all DBs under the SAME names while the app keeps running.
#                Repeatable and idempotent (mongorestore --drop per collection,
#                disable with --no-drop). Ends with verify-migration.sh
#                --allow-drift. Prints the measured duration for planning.
#   --final      cutover copy: backup -> stop writers -> dump|restore -> strict
#                verify -> prints the exact switch steps. On any failure the
#                writers are restarted (still pointing at the local DB).
#                The script does NOT edit .env.production or recreate services.
#
# Options: --dbs a,b   --no-drop   --yes   --skip-preflight   --backup-dir D
#          --env-file F
# Secrets: NEW_URI from env or $MANAGED_ENV (chmod 600) - never on the command
# line. The tools run in a throwaway mongo:7 container; credentials live in a
# 0600 temp dir mounted read-only and deleted on exit. Output is masked.
# Exit: 0 ok | 1 failure | 2 usage/config error
# =============================================================================
set -euo pipefail

DIR="${COACHIFY_DIR:-$HOME/production/coachify}"
ENV_FILE="${ENV_FILE:-$DIR/.env.production}"
MANAGED_ENV="${MANAGED_ENV:-$DIR/.managed-db.env}"
TOOLS_IMAGE="${TOOLS_IMAGE:-mongo:7}"
LOCAL_CTR="${LOCAL_CTR:-coachify-mongodb}"
TOOLS_MEM="${TOOLS_MEM:-384m}"
DEFAULT_DBS="COACHIFY CONTENT identifier statistics_read statistics_write users workout-management"
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups/mongodb}"
RATE_FAST_MBS="${RATE_FAST_MBS:-8}"   # logical MB/s, optimistic (estimate only)
RATE_SLOW_MBS="${RATE_SLOW_MBS:-1.5}" # logical MB/s, pessimistic
# Services that write to MongoDB (stopped for --final). notification-api and
# frontend do not use Mongo directly; they stay up (frontend serves the UI, API
# calls fail until the switch - see docs/MANAGED-DB-MIGRATION.md for the nginx
# maintenance page).
WRITERS=(tracker-api statistics-api identifier-api account-api chat-api content-api invitation-api payments-api workout-api)
# Every service whose env_file is .env.production: recreate ALL of them together at the switch.
ALL_SERVICES=(identifier-api notification-api content-api workout-api tracker-api statistics-api payments-api account-api invitation-api chat-api frontend)
MODE=""; DBS_OVERRIDE=""; DROP=true; ASSUME_YES=false; SKIP_PREFLIGHT=false
SECRETS=()
TMP=""
NET=""
WRITERS_STOPPED=false
EXTRA_DOCKER=()

die() { echo "ERROR: $*" >&2; exit 2; }

env_get() { # file key -> value (quotes/CR stripped); empty if absent
  [[ -f $1 ]] || return 0
  grep -E "^[[:space:]]*(export[[:space:]]+)?$2=" "$1" 2>/dev/null | tail -1 \
    | sed -E 's/\r$//; s/^[^=]*=//; s/^["'"'"']//; s/["'"'"']$//' || true
}

urlenc() {
  local s=$1 i c out="" LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in [a-zA-Z0-9.~_-]) out+=$c ;; *) out+=$(printf '%%%02X' "'$c") ;; esac
  done
  printf '%s' "$out"
}
urldec() { { printf '%b' "${1//%/\\x}"; } 2>/dev/null || printf '%s' "$1"; }

jsq() { # bash string -> JS double-quoted literal
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

redact() { # stdin -> stdout; masks URI credentials and any registered secret
  local line s
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(sed -E 's#(mongodb(\+srv)?://)[^@/[:space:]]*@#\1***:***@#g' <<<"$line")
    for s in "${SECRETS[@]:-}"; do [[ -n $s ]] && line=${line//"$s"/***}; done
    printf '%s\n' "$line"
  done
}

register_uri_secrets() { # uri -> adds password (raw + decoded) to SECRETS
  local u=${1#*://} pw
  [[ $u == *@* ]] || return 0
  u=${u%@*}; pw=${u#*:}
  [[ $u == *:* && -n $pw ]] || return 0
  SECRETS+=("$pw" "$(urldec "$pw")")
}

uri_host() { local u=${1#*://}; u=${u##*@}; u=${u%%[/?]*}; printf '%s' "$u"; }
uri_user() { local u=${1#*://}; [[ $u == *@* ]] || return 0; u=${u%@*}; u=${u%%:*}; u=$(urldec "$u"); printf '%s***' "${u:0:3}"; }

strip_db_path() { # drop /dbname so tools do not treat it as --db; keep query
  sed -E 's#^(mongodb(\+srv)?://[^/?]+)/?([^?]*)(\?.*)?$#\1/\4#' <<<"$1"
}

cleanup() { [[ -n $TMP && -d $TMP ]] && rm -rf "$TMP"; return 0; }

load_new_uri() {
  NEW_URI="${NEW_URI:-}"
  [[ -n $NEW_URI ]] || NEW_URI=$(env_get "$MANAGED_ENV" NEW_URI)
  [[ -n $NEW_URI ]] || die "NEW_URI not set (env var or $MANAGED_ENV). Never paste it on the command line."
  case $NEW_URI in mongodb+srv://* | mongodb://*) ;; *) die "NEW_URI must start with mongodb+srv:// or mongodb://" ;; esac
  case $(uri_host "$NEW_URI") in
    mongodb:* | mongodb | localhost* | 127.* ) die "NEW_URI points at the LOCAL mongodb; refusing." ;;
  esac
  register_uri_secrets "$NEW_URI"
}

local_uri() {
  if [[ -n ${LOCAL_URI:-} ]]; then printf '%s' "$LOCAL_URI"; return; fi
  local pw="${LOCAL_MONGO_ROOT_PASSWORD:-}" usr="${LOCAL_MONGO_ROOT_USER:-adminUser}"
  [[ -n $pw ]] || pw=$(env_get "$ENV_FILE" LOCAL_MONGO_ROOT_PASSWORD)
  [[ -n $pw ]] || pw=$(env_get "$DIR/.env" LOCAL_MONGO_ROOT_PASSWORD)
  [[ -n $pw ]] || return 1
  SECRETS+=("$pw" "$(urlenc "$pw")")
  printf 'mongodb://%s:%s@%s:27017/?authSource=admin' "$usr" "$(urlenc "$pw")" "${LOCAL_HOST:-mongodb}"
}

net_of() { docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$LOCAL_CTR" 2>/dev/null | head -1; }

tool_run() { # args after: passed to `sh`; /cfg = temp dir (ro)
  docker run --rm -i --network "$NET" --memory "$TOOLS_MEM" --entrypoint sh -v "$TMP:/cfg:ro" "$TOOLS_IMAGE" "$@"
}

discover_dbs() { # prints db names (one per line) from the local instance; non-zero if impossible
  local lu; lu=$(local_uri) || return 1
  printf 'const L = new Mongo(%s);\nL.getDB("admin").adminCommand({listDatabases:1,nameOnly:true}).databases.map(d=>d.name).filter(n=>!["admin","local","config"].includes(n)).forEach(n=>print(n));\n' "$(jsq "$lu")" >"$TMP/dbs.js"
  tool_run -c 'mongosh --nodb --quiet --file /cfg/dbs.js' 2>/dev/null
}

# ---- migrate-specific -------------------------------------------------------
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# override: run as the invoking user (cfg files are 0600), HOME writable for mongosh
tool_run() {
  docker run --rm -i --network "$NET" --memory "$TOOLS_MEM" --entrypoint sh \
    -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$TMP:/cfg:ro" ${EXTRA_DOCKER[@]+"${EXTRA_DOCKER[@]}"} "$TOOLS_IMAGE" "$@"
}

compose() { (cd "$DIR" && docker compose --env-file .env.production --env-file versions.env -f docker-compose.prod.yml "$@"); }

write_cfg() { # writes /cfg/local.yml + new.yml (mongodump/mongorestore --config, key "uri")
  local lu; lu=$(local_uri) || die "local root password not found (LOCAL_MONGO_ROOT_PASSWORD in env or $ENV_FILE)"
  printf 'uri: %s\n' "$(jsq "$lu")" >"$TMP/local.yml"
  printf 'uri: %s\n' "$(jsq "$(strip_db_path "$NEW_URI")")" >"$TMP/new.yml"
  chmod 600 "$TMP"/*.yml
}

local_stats() { # prints: STAT<TAB>db<TAB>dataBytes<TAB>storageBytes<TAB>indexBytes<TAB>collections<TAB>objects
  local lu; lu=$(local_uri) || die "local root password not found"
  {
    printf 'const L = new Mongo(%s);\n' "$(jsq "$lu")"
    cat <<'JS'
L.getDB("admin").adminCommand({ listDatabases: 1, nameOnly: true }).databases.map(d => d.name)
  .filter(n => !["admin", "local", "config"].includes(n)).forEach(n => {
    const s = L.getDB(n).stats();
    print(["STAT", n, s.dataSize, s.storageSize, s.indexSize, s.collections, s.objects].join("\t"));
  });
JS
  } >"$TMP/stats.js"
  tool_run -c 'mongosh --nodb --quiet --file /cfg/stats.js'
}

estimate() { # stdin: STAT lines -> prints size + time estimate
  awk -F'\t' -v fast="$RATE_FAST_MBS" -v slow="$RATE_SLOW_MBS" '
    $1=="STAT" { data+=$3; stor+=$4; idx+=$5; c+=$6; o+=$7 }
    END {
      mb=data/1048576; lo=(30+mb/fast+c*0.4)/60; hi=(60+mb/slow+c*1.5)/60
      printf "data=%.1f MB  storage=%.1f MB  indexes=%.1f MB  collections=%d  documents=%d\n", mb, stor/1048576, idx/1048576, c, o
      printf "copy estimate: %.1f - %.1f min (dump|restore, assumes %s-%s MB/s logical + index builds)\n", lo, hi, slow, fast
      printf "ESTIMATE_HIGH_MIN=%.1f\n", hi
    }'
}

copy_dbs() { # $1 = db list; dump|restore per DB in one throwaway container
  local dbs=$1 drop_flag="" d
  for d in $dbs; do [[ $d =~ ^[A-Za-z0-9_.-]+$ ]] || die "unsafe database name: $d"; done
  $DROP && drop_flag="--drop"
  local script
  script='set -euo pipefail
for db in '"$dbs"'; do
  echo "== $db: dump | restore"
  mongodump --config /cfg/local.yml --db "$db" --archive --gzip --quiet \
    | mongorestore --config /cfg/new.yml --archive --gzip --nsInclude "$db.*" '"$drop_flag"' \
        --numParallelCollections 2 --numInsertionWorkersPerCollection 2 --stopOnError --quiet
done'
  local rc=0
  tool_run -c 'exec bash -c "$1"' _ "$script" 2>&1 | redact || rc=${PIPESTATUS[0]}
  return "$rc"
}

backup_local() { # $1=dbs -> per-DB gzip archives in $BACKUP_DIR/pre-managed-<ts>/
  local dbs=$1 ts dest
  ts=$(date +%Y%m%d-%H%M%S)
  dest="$BACKUP_DIR/pre-managed-$ts"
  mkdir -p "$dest"; chmod 700 "$BACKUP_DIR" "$dest"
  local script
  script='set -euo pipefail
for db in '"$dbs"'; do
  mongodump --config /cfg/local.yml --db "$db" --archive="/bk/$db.archive.gz" --gzip --quiet
done'
  local rc=0
  EXTRA_DOCKER=(-v "$dest:/bk")
  tool_run -c 'exec bash -c "$1"' _ "$script" 2>&1 | redact || rc=${PIPESTATUS[0]}
  EXTRA_DOCKER=()
  chmod 600 "$dest"/* 2>/dev/null || true
  [[ $rc -eq 0 ]] || return "$rc"
  BACKUP_PATH=$dest
  log "backup written: $dest ($(du -sh "$dest" | cut -f1))"
}

run_verify() { # extra args to verify-migration.sh
  local v; v="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verify-migration.sh"
  [[ -x $v || -f $v ]] || die "verify-migration.sh not found next to this script"
  NEW_URI="$NEW_URI" bash "$v" --dbs "${DBS_LIST// /,}" --env-file "$ENV_FILE" "$@"
}

run_preflight() {
  local p; p="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/preflight-managed.sh"
  [[ -f $p ]] || die "preflight-managed.sh not found next to this script"
  NEW_URI="$NEW_URI" bash "$p" --dbs "${DBS_LIST// /,}" --env-file "$ENV_FILE"
}

on_exit() {
  local rc=$?
  if ((rc != 0)) && $WRITERS_STOPPED; then
    echo
    echo "!! FAILED after writers were stopped. Restarting them on the LOCAL database (env unchanged)..."
    compose start "${WRITERS[@]}" >/dev/null 2>&1 \
      && echo "   writers restarted. Fix the problem and retry --final in the next window." \
      || echo "   AUTOMATIC RESTART FAILED. Run now: cd $DIR && docker compose --env-file .env.production --env-file versions.env -f docker-compose.prod.yml start ${WRITERS[*]}"
  fi
  cleanup
  exit "$rc"
}

print_switch_steps() {
  local ts; ts=$(date +%Y%m%d-%H%M)
  cat <<EOF

================ SWITCH STEPS (run on the server; writers are still STOPPED) ================
 1. cd $DIR
    cp -p .env.production .env.production.pre-managed-$ts
 2. Edit .env.production (use an editor; do not echo the URI in the shell). Replace the
    host/credentials/options of ALL THREE variables together, keeping each variable's own
    database path if it has one: MONGODB_URI, MONGO_URI, MONGO_URL
    (add retryWrites=true&w=majority; the user needs authSource=admin, the Atlas default).
    Check: grep -cE '^(MONGODB_URI|MONGO_URI|MONGO_URL)=mongodb\+srv://' .env.production   -> must print 3
 3. Recreate ALL services together (env_file is read at container create time):
    docker compose --env-file .env.production --env-file versions.env -f docker-compose.prod.yml \\
      up -d --no-deps --pull never ${ALL_SERVICES[*]}
    (alternative with health gates + auto-rollback of the image set: scripts/deploy-service.sh all --local)
 4. Health gates: every container 'healthy'/Up after ~60s:
      docker ps --format '{{.Names}} {{.Status}}' | grep coachify
    then public smoke test (login, load a workout, a statistics page) and
      docker logs --since 3m coachify-account-api 2>&1 | grep -iE 'mongo|error' | head
 5. ROLLBACK if anything is wrong in the first minutes: cp -p .env.production.pre-managed-$ts .env.production,
    repeat step 3. The local mongodb container is untouched and still has all data
    (writes made on the managed cluster after the switch must be exported back if rolling back late).
 6. Keep coachify-mongodb running (idle) until T+7d. Do NOT remove its volume.
=============================================================================================
EOF
}

main() {
  while (($#)); do
    case $1 in
      --dry-run) MODE=dry-run; shift ;;
      --rehearsal) MODE=rehearsal; shift ;;
      --final) MODE=final; shift ;;
      --dbs) DBS_OVERRIDE=${2:-}; shift 2 ;;
      --no-drop) DROP=false; shift ;;
      --yes) ASSUME_YES=true; shift ;;
      --skip-preflight) SKIP_PREFLIGHT=true; shift ;;
      --backup-dir) BACKUP_DIR=${2:-}; shift 2 ;;
      --env-file) ENV_FILE=${2:-}; shift 2 ;;
      -h | --help) sed -n '2,26p' "$0"; exit 0 ;;
      *) die "unknown option: $1 (see --help)" ;;
    esac
  done
  [[ -n $MODE ]] || die "choose one mode: --dry-run | --rehearsal | --final"
  command -v docker >/dev/null || die "docker not found (run on the server)"
  TMP=$(umask 077; mktemp -d); trap on_exit EXIT
  load_new_uri
  NET=$(net_of); [[ -n $NET ]] || die "container $LOCAL_CTR not found / no network (set LOCAL_CTR)"
  [[ -f $DIR/docker-compose.prod.yml && -f $ENV_FILE ]] || die "compose dir/env not found under $DIR"

  if [[ -n $DBS_OVERRIDE ]]; then DBS_LIST=${DBS_OVERRIDE//,/ }
  else DBS_LIST=$(discover_dbs | tr '\n' ' ') || true; [[ -n ${DBS_LIST// /} ]] || DBS_LIST=$DEFAULT_DBS; fi
  DBS_LIST=${DBS_LIST% }

  echo "== migrate-to-managed: mode=$MODE =="
  echo "source : $LOCAL_CTR   target: $(uri_host "$NEW_URI") (user $(uri_user "$NEW_URI"))"
  echo "dbs    : $DBS_LIST   drop=$DROP   image=$TOOLS_IMAGE"

  write_cfg
  log "local database sizes"
  local stats est
  stats=$(local_stats) || die "cannot read local stats (credentials? $LOCAL_CTR up?)"
  est=$(estimate <<<"$stats")
  grep -v '^ESTIMATE' <<<"$est" | sed 's/^/  /'
  local est_hi; est_hi=$(sed -n 's/^ESTIMATE_HIGH_MIN=//p' <<<"$est")

  if ! $SKIP_PREFLIGHT; then
    log "preflight"
    run_preflight || die "preflight FAILED - fix before copying"
  fi

  case $MODE in
    dry-run)
      local name missing=0
      for name in "${WRITERS[@]}"; do docker inspect "coachify-$name" >/dev/null 2>&1 || { echo "  WARN container coachify-$name not found"; missing=1; }; done
      log "disk for backups ($BACKUP_DIR): $(df -h "$(dirname "$BACKUP_DIR")" 2>/dev/null | awk 'NR==2{print $4" free"}')"
      cat <<EOF

PLAN
  --rehearsal : dump|restore $DBS_LIST (app keeps running, $( $DROP && echo "--drop" || echo "no drop" )), then verify --allow-drift
  --final     : backup -> stop writers (${WRITERS[*]}) -> dump|restore -> strict verify -> print switch steps
  expected final maintenance window: ~${est_hi:-?} min copy + verify + ~10 min env switch/recreate
Nothing was written. (dry-run)
EOF
      ;;
    rehearsal)
      local t0=$SECONDS
      log "REHEARSAL copy (app keeps running; counts may drift)"
      copy_dbs "$DBS_LIST" || die "copy failed"
      log "copy took $((SECONDS - t0))s - use this to size the final window"
      run_verify --allow-drift || die "verification reported mismatches"
      log "rehearsal OK in $((SECONDS - t0))s total"
      ;;
    final)
      if ! $ASSUME_YES; then
        [[ -t 0 ]] || die "not a terminal; pass --yes to confirm"
        echo
        echo "FINAL cutover copy. This will STOP: ${WRITERS[*]}"
        echo "and overwrite $DBS_LIST on the managed cluster ($(uri_host "$NEW_URI"))."
        read -r -p "Type CUTOVER to continue: " ans
        [[ $ans == CUTOVER ]] || die "aborted"
      fi
      local t0=$SECONDS
      log "1/5 backup of local data"
      backup_local "$DBS_LIST" || die "backup failed - nothing stopped"
      log "2/5 stopping writers"
      WRITERS_STOPPED=true
      compose stop "${WRITERS[@]}" >/dev/null
      sleep 5
      log "3/5 final dump|restore"
      copy_dbs "$DBS_LIST" || die "copy failed"
      log "4/5 strict verification"
      run_verify || die "verification FAILED - switch NOT safe"
      WRITERS_STOPPED=false   # success: keep writers down, operator performs the switch
      log "5/5 done in $((SECONDS - t0))s. Backup: ${BACKUP_PATH:-n/a}"
      print_switch_steps
      ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
