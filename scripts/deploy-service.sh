#!/usr/bin/env bash
# deploy-service.sh - self-checking, auto-rollback deploy of one (or all) Coachify service(s).
# See docs/DEPLOY-SCRIPT.md. Exit codes: 0 ok | 2 preflight/usage | 3 image missing | 4 rolled back | 5 rollback failed
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: deploy-service.sh <service|all> [<full-sha>|latest-from-versions] [options]
  --host user@host     SSH target (default lborx@192.168.1.21); ignored with --local
  --local              run on the server itself (no ssh)
  --dry-run            read-only preflight + print plan, change nothing
  --no-smoke           skip public smoke tests (frontend)
  --wait-image <min>   wait up to <min> minutes for the image to be published (default 20)
  --force              deploy even if the current container is unhealthy
EOF
}

# ---------------------------------------------------------------- service map
# service -> VERSION var | container | internal port | image repo | health path
declare -A SVC_VAR=(
  [identifier-api]=IDENTIFIER_API_VERSION [notification-api]=NOTIFICATION_API_VERSION
  [content-api]=CONTENT_API_VERSION [workout-api]=WORKOUT_API_VERSION
  [tracker-api]=TRACKER_API_VERSION [statistics-api]=STATISTICS_API_VERSION
  [payments-api]=PAYMENTS_API_VERSION [account-api]=ACCOUNT_API_VERSION
  [invitation-api]=INVITATION_API_VERSION [chat-api]=CHAT_API_VERSION
  [frontend]=FRONTEND_VERSION
)
declare -A SVC_CTR=(
  [identifier-api]=coachify-identifier-api [notification-api]=coachify-notification-api
  [content-api]=coachify-content-api [workout-api]=coachify-workout-api
  [tracker-api]=coachify-tracker-api [statistics-api]=coachify-statistics-api
  [payments-api]=coachify-payments-api [account-api]=coachify-account-api
  [invitation-api]=coachify-invitation-api [chat-api]=coachify-chat-api
  [frontend]=coachify-frontend
)
declare -A SVC_PORT=(
  [identifier-api]=8080 [notification-api]=8081 [account-api]=8082 [chat-api]=8083
  [content-api]=8084 [invitation-api]=8085 [payments-api]=8086 [workout-api]=8087
  [tracker-api]=8088 [statistics-api]=8089 [frontend]=3000
)
declare -A SVC_IMG=(
  [identifier-api]=coachify-identifier-api [notification-api]=coachify-notification-api
  [content-api]=coachify-content-api [workout-api]=coachify-workout-api
  [tracker-api]=coachify-tracker-api [statistics-api]=coachify-statistics-api
  [payments-api]=coachify-payments-api [account-api]=coachify-account-api
  [invitation-api]=coachify-invitation-api [chat-api]=coachify-chat-api
  [frontend]=coachify-frontend
)
declare -A SVC_HPATH=([frontend]=/api/auth/session)   # others default to /health
DEPLOY_ORDER=(identifier-api notification-api content-api workout-api tracker-api
  statistics-api payments-api account-api invitation-api chat-api frontend)

# ---------------------------------------------------------------- settings (env-overridable for tests)
DIR="${COACHIFY_DIR:-$HOME/production/coachify}"
REGISTRY="${REGISTRY_PREFIX:-ghcr.io/sport-stride}"
NGINX_CTR="${NGINX_CTR:-coachify-nginx-proxy}"
SMOKE_BASE="${SMOKE_BASE:-https://app.coachify.tn}"
SMOKE_UA="${SMOKE_UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
SCAN_WINDOW="${SCAN_WINDOW:-60}"
POLL="${POLL:-3}"
WAIT_SLEEP="${WAIT_SLEEP:-20}"
MIN_DISK_KB=$((5 * 1024 * 1024))

HOST="lborx@192.168.1.21"
LOCAL=${DEPLOY_LOCAL:-0}
DRY=0 SMOKE=1 FORCE=0 WAIT_MIN=20
TARGET="" SHA_ARG=""
CUR_SVC="" OLD_SHA="" NEW_SHA="" LOCK_HELD=0
declare -a SUMMARY=()

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(ts)" "$*" >&2; }

record() { # service old new result
  [[ $DRY -eq 1 ]] && return 0
  printf '%s user=%s service=%s old=%s new=%s result=%s\n' "$(ts)" "${USER:-$(id -un)}" "$1" "$2" "$3" "$4" \
    >>"$DIR/deploy.log" 2>/dev/null || true
}

fail() { # rc msg
  local rc=$1
  shift
  printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2
  [[ -n $CUR_SVC ]] && record "$CUR_SVC" "$OLD_SHA" "$NEW_SHA" "FAIL(rc=$rc): $*"
  exit "$rc"
}

# ---------------------------------------------------------------- pure helpers (unit-tested)
is_sha() { [[ ${1:-} =~ ^[0-9a-f]{40}$ ]]; }

get_ver() { # file var
  local line
  line=$(grep -E "^$2=" "$1" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}

set_ver() { # file var value  (idempotent; appends if missing)
  local f=$1 k=$2 v=$3 tmp
  tmp=$(mktemp "${f}.tmp.XXXXXX")
  awk -v k="$k" -v v="$v" 'BEGIN{d=0} index($0, k"=")==1 {if(!d){print k"="v; d=1}; next} {print} END{if(!d) print k"="v}' "$f" >"$tmp"
  cat "$tmp" >"$f"
  rm -f "$tmp"
}

next_backup_path() { # versions-file -> versions.env.bak-YYYYMMDD<letter>
  local f=$1 day l p
  day=$(date +%Y%m%d)
  for l in {a..z}; do
    p="$f.bak-$day$l"
    [[ -e $p ]] || {
      printf '%s' "$p"
      return 0
    }
  done
  return 1
}

lock_acquire() { # lockfile
  local lf=$1 pid
  if [[ -e $lf ]]; then
    pid=$(cat "$lf" 2>/dev/null || true)
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    warn "stale lock (pid '${pid:-?}') removed"
    rm -f "$lf"
  fi
  (
    set -C
    echo "$$" >"$lf"
  ) 2>/dev/null || return 1
  LOCK_HELD=1
}

lock_release() { # lockfile
  if [[ $LOCK_HELD -eq 1 ]]; then rm -f "$1"; LOCK_HELD=0; fi
}

# ---------------------------------------------------------------- docker helpers
compose() {
  (cd "$DIR" && docker compose --env-file .env.production --env-file versions.env -f docker-compose.prod.yml "$@")
}

run() { # mutating command wrapper
  if [[ $DRY -eq 1 ]]; then log "[dry-run] $*"; return 0; fi
  "$@"
}

container_state() { # ctr -> "status|health|restarts"
  docker inspect -f '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.RestartCount}}' "$1" 2>/dev/null || echo "missing|none|0"
}

container_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" 2>/dev/null | awk '{print $1}'
}

# prints http code (000 = no answer)
http_code() { # ctr port path
  local ip
  ip=$(container_ip "$1")
  [[ -n $ip ]] || { echo 000; return 0; }
  curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$ip:$2$3" 2>/dev/null || echo 000
}

# 0 = healthy; sets GATE_REASON on failure
health_gate() { # svc
  local svc=$1 ctr=${SVC_CTR[$1]} port=${SVC_PORT[$1]} path=${SVC_HPATH[$1]:-/health}
  local deadline=$((SECONDS + HEALTH_TIMEOUT)) st hs rc code
  GATE_REASON="timeout after ${HEALTH_TIMEOUT}s"
  while ((SECONDS < deadline)); do
    IFS='|' read -r st hs rc <<<"$(container_state "$ctr")"
    if [[ $st == exited || $st == dead || $st == restarting || $st == missing || $hs == unhealthy ]]; then
      GATE_REASON="container state=$st health=$hs"
      return 1
    fi
    if [[ ${rc:-0} -gt 0 ]]; then
      GATE_REASON="container restarted ${rc}x (crash loop)"
      return 1
    fi
    if [[ $st == running && ($hs == healthy || $hs == none) ]]; then
      code=$(http_code "$ctr" "$port" "$path")
      if [[ $code =~ ^[23] ]]; then
        GATE_REASON="ok (docker=$hs http=$code)"
        return 0
      elif [[ $code =~ ^4 ]]; then
        warn "$svc $path -> HTTP $code (alive, path not verified)"
        GATE_REASON="ok (docker=$hs http=$code, alive only)"
        return 0
      fi
      GATE_REASON="http $code on $path"
    fi
    sleep "$POLL"
  done
  return 1
}

# 0 = clean; prints offending lines on failure
log_scan() { # ctr since-epoch
  local hits
  hits=$(docker logs --since "$2" "$1" 2>&1 | grep -Ei 'panic|fatal' | head -n 3 | cut -c1-200 || true)
  if [[ -n $hits ]]; then
    printf '%s\n' "$hits" >&2
    return 1
  fi
}

nginx_reload() {
  if docker inspect "$NGINX_CTR" >/dev/null 2>&1; then
    docker exec "$NGINX_CTR" nginx -t >/dev/null 2>&1 || { warn "nginx -t failed"; return 1; }
    docker exec "$NGINX_CTR" nginx -s reload >/dev/null 2>&1 || { warn "nginx reload failed"; return 1; }
    log "nginx reloaded"
  else
    warn "$NGINX_CTR not found, skipped reload"
  fi
}

smoke_url() { # path -> 0 if 200 within 5 tries
  local i code
  for i in 1 2 3 4 5; do
    code=$(curl -s -o /dev/null -m 10 -A "$SMOKE_UA" -w '%{http_code}' "$SMOKE_BASE$1" 2>/dev/null || echo 000)
    if [[ $code == 200 ]]; then log "smoke $1 -> 200"; return 0; fi
    sleep "$POLL"
  done
  warn "smoke $1 -> $code"
  return 1
}

post_checks() { # svc
  local svc=$1
  nginx_reload || return 1
  if [[ $svc == frontend && $SMOKE -eq 1 ]]; then
    smoke_url /auth/signin && smoke_url /api/auth/providers || return 1
  fi
  if [[ -f $DIR/tools/perf/probe.mjs ]] && command -v node >/dev/null 2>&1; then
    log "perf probe (report only):"
    (cd "$DIR" && node tools/perf/probe.mjs --dry-run 2>&1 | tail -n 5) || true
  fi
}

# ---------------------------------------------------------------- preflight
preflight_global() {
  [[ -d $DIR ]] || fail 2 "project dir $DIR missing"
  local f
  for f in docker-compose.prod.yml versions.env .env.production; do
    [[ -f $DIR/$f ]] || fail 2 "$DIR/$f missing"
  done
  local avail
  avail=$(df -Pk "$DIR" | awk 'NR==2{print $4}')
  [[ ${avail:-0} -gt $MIN_DISK_KB ]] || fail 2 "disk free $((${avail:-0} / 1024)) MB < 5120 MB"
  if command -v free >/dev/null 2>&1; then
    local mem swt swu
    mem=$(free -m | awk '/^Mem:/{print $7}')
    swt=$(free -m | awk '/^Swap:/{print $2}')
    swu=$(free -m | awk '/^Swap:/{print $3}')
    [[ ${mem:-9999} -lt 200 ]] && warn "low available memory: ${mem} MB"
    [[ ${swt:-0} -gt 0 && $((swu * 100 / swt)) -gt 90 ]] && warn "swap ${swu}/${swt} MB nearly exhausted"
  fi
  local err
  if ! err=$(compose config -q 2>&1); then
    fail 2 "compose file invalid: $(printf '%s' "$err" | head -n 3 | cut -c1-200)"
  fi
  log "preflight global ok (disk $((avail / 1024)) MB free)"
}

resolve_service() { # name -> canonical or empty
  local n=$1
  if [[ -n ${SVC_VAR[$n]:-} ]]; then echo "$n"; elif [[ -n ${SVC_VAR[$n-api]:-} ]]; then echo "$n-api"; fi
}

# ---------------------------------------------------------------- image wait
image_local() { docker image inspect "$1" >/dev/null 2>&1; }

wait_for_image() { # image
  local img=$1 deadline=$((SECONDS + WAIT_MIN * 60)) out attempt=0
  if image_local "$img"; then log "image already local: $img"; return 0; fi
  if [[ $DRY -eq 1 ]]; then log "[dry-run] would docker pull $img (retry up to ${WAIT_MIN} min)"; return 0; fi
  while :; do
    attempt=$((attempt + 1))
    if out=$(timeout 300 docker pull "$img" 2>&1); then
      log "pulled $img (attempt $attempt)"
      return 0
    fi
    if grep -qiE 'not found|manifest unknown|no such manifest' <<<"$out"; then
      log "image not published yet (attempt $attempt); CI not done"
    else
      log "pull failed (attempt $attempt): $(printf '%s' "$out" | tail -n 1 | cut -c1-160)"
    fi
    ((SECONDS + WAIT_SLEEP < deadline)) || break
    sleep "$WAIT_SLEEP"
  done
  printf '[%s] IMAGE NOT PUBLISHED - nothing changed (%s)\n' "$(ts)" "$img" >&2
  record "$CUR_SVC" "$OLD_SHA" "$NEW_SHA" "IMAGE NOT PUBLISHED"
  exit 3
}

# ---------------------------------------------------------------- rollback
do_rollback() { # svc backup prev_image_id
  local svc=$1 bak=$2 prev_id=$3 img
  img="$REGISTRY/${SVC_IMG[$svc]}:$OLD_SHA"
  log "ROLLBACK: restoring versions.env from $(basename "$bak")"
  cat "$bak" >"$DIR/versions.env"
  if ! image_local "$img" && [[ -n $prev_id ]]; then
    docker tag "$prev_id" "$img" 2>/dev/null || warn "could not retag previous image"
  fi
  compose up -d --no-deps --pull never "$svc" >/dev/null 2>&1 || true
  if health_gate "$svc"; then
    nginx_reload || true
    record "$svc" "$OLD_SHA" "$NEW_SHA" "ROLLED BACK to $OLD_SHA"
    printf '[%s] ROLLED BACK to %s (%s healthy: %s)\n' "$(ts)" "$OLD_SHA" "$svc" "$GATE_REASON" >&2
    exit 4
  fi
  record "$svc" "$OLD_SHA" "$NEW_SHA" "ROLLBACK FAILED: $GATE_REASON"
  printf '[%s] ROLLBACK FAILED for %s: %s. MANUAL ACTION NEEDED (backup: %s)\n' "$(ts)" "$svc" "$GATE_REASON" "$bak" >&2
  exit 5
}

# ---------------------------------------------------------------- deploy one
deploy_one() { # svc sha|latest-from-versions
  local svc=$1 want=$2 var=${SVC_VAR[$1]} ctr=${SVC_CTR[$1]}
  local t0=$SECONDS img prev_id prev_digest bak st hs rc code up_at
  CUR_SVC=$svc
  OLD_SHA=$(get_ver "$DIR/versions.env" "$var")
  [[ $want == latest-from-versions ]] && want=$OLD_SHA
  NEW_SHA=$want
  is_sha "$NEW_SHA" || fail 2 "$svc: '$NEW_SHA' is not a 40-hex sha"
  img="$REGISTRY/${SVC_IMG[$svc]}:$NEW_SHA"
  log "=== $svc: ${OLD_SHA:-none} -> $NEW_SHA"

  # 1. current container health
  IFS='|' read -r st hs rc <<<"$(container_state "$ctr")"
  code=000
  [[ $st == running ]] && code=$(http_code "$ctr" "${SVC_PORT[$svc]}" "${SVC_HPATH[$svc]:-/health}")
  if [[ $st != running || ! ($hs == healthy || $hs == none) || ! $code =~ ^[234] ]]; then
    if [[ $FORCE -eq 1 ]]; then
      warn "$svc unhealthy before deploy (state=$st health=$hs http=$code), continuing (--force)"
    else
      fail 2 "$svc unhealthy BEFORE deploy (state=$st health=$hs http=$code); use --force to override"
    fi
  fi

  # 2. image (versions.env untouched until this succeeds)
  wait_for_image "$img"

  if [[ $DRY -eq 1 ]]; then
    log "[dry-run] would back up versions.env -> $(next_backup_path "$DIR/versions.env")"
    log "[dry-run] would set $var=$NEW_SHA"
    log "[dry-run] would run: docker compose up -d --no-deps --pull never $svc"
    log "[dry-run] would health-gate (${HEALTH_TIMEOUT}s), scan logs ${SCAN_WINDOW}s, nginx reload$([[ $svc == frontend && $SMOKE -eq 1 ]] && echo ', public smoke')"
    SUMMARY+=("$svc ${OLD_SHA:0:12} -> ${NEW_SHA:0:12} DRY-RUN")
    CUR_SVC=""
    return 0
  fi

  # 3. backup + previous image
  bak=$(next_backup_path "$DIR/versions.env") || fail 2 "no free backup letter today"
  cp -p "$DIR/versions.env" "$bak"
  prev_id=$(docker inspect -f '{{.Image}}' "$ctr" 2>/dev/null || true)
  prev_digest=$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' "$prev_id" 2>/dev/null || true)
  log "backup: $(basename "$bak"); previous image id=${prev_id:-?} digest=${prev_digest:-n/a}"

  # 4. switch + gate
  set_ver "$DIR/versions.env" "$var" "$NEW_SHA"
  local t_up=$SECONDS
  up_at=$(date +%s)
  if ! compose up -d --no-deps --pull never "$svc" >/dev/null 2>&1; then
    warn "compose up failed"
    do_rollback "$svc" "$bak" "$prev_id"
  fi
  if ! health_gate "$svc"; then
    warn "health gate failed: $GATE_REASON"
    do_rollback "$svc" "$bak" "$prev_id"
  fi
  log "health gate ok: $GATE_REASON"
  local rest=$((SCAN_WINDOW - (SECONDS - t_up)))
  ((rest > 0)) && { log "watching logs for ${rest}s more"; sleep "$rest"; }
  if ! log_scan "$ctr" "$up_at"; then
    warn "panic/fatal found in first ${SCAN_WINDOW}s of logs"
    do_rollback "$svc" "$bak" "$prev_id"
  fi

  # 5. post checks
  if ! post_checks "$svc"; then
    warn "post-checks failed"
    do_rollback "$svc" "$bak" "$prev_id"
  fi

  record "$svc" "$OLD_SHA" "$NEW_SHA" "OK"
  SUMMARY+=("$svc ${OLD_SHA:0:12} -> ${NEW_SHA:0:12} OK health=[$GATE_REASON] $((SECONDS - t0))s")
  CUR_SVC=""
}

# ---------------------------------------------------------------- remote mode
find_agent() {
  local s
  if [[ -n ${SSH_AUTH_SOCK:-} ]] && ssh-add -l >/dev/null 2>&1; then return 0; fi
  for s in /tmp/ssh-*/agent.*; do
    [[ -S $s ]] || continue
    if SSH_AUTH_SOCK=$s ssh-add -l >/dev/null 2>&1; then
      export SSH_AUTH_SOCK=$s
      return 0
    fi
  done
  warn "no working ssh agent found; relying on default keys"
}

run_remote() { # original args
  find_agent
  local sshopts=(-o BatchMode=yes -o ConnectTimeout=10)
  ssh "${sshopts[@]}" "$HOST" true >/dev/null 2>&1 || {
    printf 'ERROR: ssh to %s failed (BatchMode)\n' "$HOST" >&2
    exit 2
  }
  log "ssh ok: $HOST"
  local args
  args=$(printf '%q ' "$@")
  # copy the script to a temp file first so remote commands cannot eat it from stdin
  ssh "${sshopts[@]}" "$HOST" \
    "f=\$(mktemp) && cat >\"\$f\" && bash \"\$f\" --local $args; rc=\$?; rm -f \"\$f\"; exit \$rc" <"${BASH_SOURCE[0]}"
}

# ---------------------------------------------------------------- main
main() {
  local orig=("$@") pos=()
  while (($#)); do
    case $1 in
      --host) HOST=${2:?--host needs value}; shift 2 ;;
      --local) LOCAL=1; shift ;;
      --dry-run) DRY=1; shift ;;
      --no-smoke) SMOKE=0; shift ;;
      --force) FORCE=1; shift ;;
      --wait-image) WAIT_MIN=${2:?--wait-image needs minutes}; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      --*) usage >&2; fail 2 "unknown option $1" ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  [[ ${#pos[@]} -ge 1 && ${#pos[@]} -le 2 ]] || { usage >&2; exit 2; }
  [[ $WAIT_MIN =~ ^[0-9]+$ ]] || fail 2 "--wait-image must be integer minutes"
  TARGET=${pos[0]}
  SHA_ARG=${pos[1]:-latest-from-versions}

  # validate before touching anything (also locally for remote runs)
  local services=()
  if [[ $TARGET == all ]]; then
    [[ $SHA_ARG == latest-from-versions ]] || fail 2 "'all' only supports latest-from-versions"
    services=("${DEPLOY_ORDER[@]}")
  else
    local canon
    canon=$(resolve_service "$TARGET")
    [[ -n $canon ]] || fail 2 "unknown service '$TARGET' (known: ${DEPLOY_ORDER[*]})"
    services=("$canon")
    [[ $SHA_ARG == latest-from-versions ]] || is_sha "$SHA_ARG" || fail 2 "'$SHA_ARG' is not a 40-hex sha"
  fi

  if [[ $LOCAL -ne 1 ]]; then
    run_remote "${orig[@]}"
    exit $?
  fi

  command -v docker >/dev/null 2>&1 || fail 2 "docker not found"
  preflight_global
  if [[ $DRY -eq 0 ]]; then
    trap 'lock_release "$DIR/.deploy.lock"' EXIT
    lock_acquire "$DIR/.deploy.lock" || fail 2 "another deploy is running (lock $DIR/.deploy.lock)"
  fi

  local svc t0=$SECONDS
  for svc in "${services[@]}"; do
    deploy_one "$svc" "$SHA_ARG"
  done

  echo
  log "SUMMARY ($((SECONDS - t0))s total)$([[ $DRY -eq 1 ]] && echo ' [dry-run]')"
  printf '  %s\n' "${SUMMARY[@]}"
  exit 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
