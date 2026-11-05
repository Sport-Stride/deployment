#!/usr/bin/env bash
# Self-test for deploy-service.sh: unit checks + end-to-end runs against stub docker/curl/ssh. Touches nothing real.
# Usage: bash scripts/deploy-service.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/deploy-service.sh"
export SCRIPT
export SCRIPT
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASS=0 FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
check() { # name cmd...
  local n=$1
  shift
  if "$@"; then ok "$n"; else bad "$n"; fi
}
eq() { [[ $1 == "$2" ]]; }

OLD=$(printf 'c%.0s' {1..40})
NEW=$(printf 'a%.0s' {1..40})
BAD=$(printf 'b%.0s' {1..40})

# ------------------------------------------------------------ stubs
BIN="$T/bin"
STUB="$T/stub"
mkdir -p "$BIN" "$STUB"

cat >"$BIN/docker" <<'EOF'
#!/usr/bin/env bash
S="$STUB_DIR"
echo "docker $*" >>"$S/calls"
case "$1" in
  compose)
    case " $* " in
      *" config "*) [[ -e $S/compose_bad ]] && { echo "bad compose" >&2; exit 1; }; exit 0 ;;
      *" up "*) exit 0 ;;
    esac ;;
  inspect)
    fmt=""; [[ $2 == -f ]] && fmt=$3
    name=${@: -1}
    case "$fmt" in
      *State.Status*)
        if [[ $name == *nginx* ]]; then echo "running|none|0"
        elif [[ -e $S/always_bad ]] || grep -q "$BAD_SHA" "$COACHIFY_DIR/versions.env"; then echo "exited|none|0"
        elif [[ -e $S/pre_bad ]]; then echo "exited|none|0"
        else echo "running|healthy|0"; fi ;;
      *IPAddress*) echo "127.0.0.1" ;;
      *.Image*) echo "sha256:previousimage" ;;
    esac
    exit 0 ;;
  image)
    if [[ $2 == inspect ]]; then
      [[ $3 == -f ]] && { echo "ghcr.io/x@sha256:digest"; exit 0; }
      grep -qxF "$3" "$S/images" 2>/dev/null; exit $?
    fi ;;
  pull)
    if [[ -e $S/pull_ok ]]; then echo "$2" >>"$S/images"; echo pulled; exit 0; fi
    echo "Error response from daemon: manifest unknown: manifest unknown" >&2; exit 1 ;;
  exec|tag) exit 0 ;;
  logs) [[ -e $S/log_panic ]] && echo 'panic: runtime error: nil pointer'; exit 0 ;;
esac
exit 0
EOF
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_DIR/calls"
printf '%s' "${STUB_CURL_CODE:-200}"
EOF
cat >"$BIN/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >>"$STUB_DIR/calls"
cat >/dev/null 2>&1 || true
exit 0
EOF
cat >"$BIN/ssh-add" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$BIN"/*

# fresh project dir per scenario
new_proj() {
  P="$T/proj"
  rm -rf "$P" "$STUB"
  mkdir -p "$P" "$STUB"
  : >"$P/docker-compose.prod.yml"
  : >"$P/.env.production"
  local v
  for v in IDENTIFIER NOTIFICATION CONTENT WORKOUT TRACKER STATISTICS PAYMENTS ACCOUNT INVITATION CHAT AI; do
    echo "${v}_API_VERSION=$OLD"
  done >"$P/versions.env"
  printf 'FRONTEND_VERSION=%s\nNGINX_VERSION=1.25\n' "$OLD" >>"$P/versions.env"
  : >"$STUB/calls"
}
deploy() { # args...  (stdout+stderr -> $OUT, rc -> $RC)
  OUT=$(env PATH="$BIN:$PATH" STUB_DIR="$STUB" BAD_SHA="$BAD" COACHIFY_DIR="$P" \
    HEALTH_TIMEOUT=3 SCAN_WINDOW=0 POLL=1 WAIT_SLEEP=1 \
    bash "$SCRIPT" "$@" 2>&1)
  RC=$?
}
vfile() { cat "$P/versions.env"; }

# ------------------------------------------------------------ unit checks
echo "== unit"
# shellcheck source=deploy-service.sh
source "$SCRIPT"
set +e # sourcing enabled -e; assertions handle their own status

check "is_sha accepts 40 hex" is_sha "$NEW"
check "is_sha rejects short" bash -c 'source "$SCRIPT"; ! is_sha abc123' _
check "is_sha rejects uppercase" bash -c 'source "$SCRIPT"; ! is_sha "$1"' _ "${NEW^^}"
check "is_sha rejects 41 chars" bash -c 'source "$SCRIPT"; ! is_sha "$1"' _ "${NEW}a"
check "is_sha rejects empty" bash -c 'source "$SCRIPT"; ! is_sha ""' _

U="$T/unit"
mkdir -p "$U"
printf '# c\nFOO_VERSION=1\nBAR=2\n' >"$U/v.env"
set_ver "$U/v.env" FOO_VERSION "$NEW"
check "set_ver replaces" eq "$(get_ver "$U/v.env" FOO_VERSION)" "$NEW"
h1=$(md5sum <"$U/v.env")
set_ver "$U/v.env" FOO_VERSION "$NEW"
check "set_ver idempotent" eq "$(md5sum <"$U/v.env")" "$h1"
set_ver "$U/v.env" NEW_VERSION "$OLD"
check "set_ver appends missing" eq "$(get_ver "$U/v.env" NEW_VERSION)" "$OLD"
check "set_ver keeps other lines" grep -qx 'BAR=2' "$U/v.env"
check "set_ver no prefix clash" bash -c 'source "$SCRIPT"; printf "X_FOO=1\nFOO=2\n" >"$1"; set_ver "$1" FOO 9; grep -qx "X_FOO=1" "$1" && grep -qx "FOO=9" "$1"' _ "$U/p.env"

day=$(date +%Y%m%d)
: >"$U/versions.env"
check "backup first letter a" eq "$(next_backup_path "$U/versions.env")" "$U/versions.env.bak-${day}a"
: >"$U/versions.env.bak-${day}a"
: >"$U/versions.env.bak-${day}b"
check "backup next free letter c" eq "$(next_backup_path "$U/versions.env")" "$U/versions.env.bak-${day}c"
: >"$U/versions.env.bak-${day}d"
check "backup fills first gap (c, not e)" eq "$(next_backup_path "$U/versions.env")" "$U/versions.env.bak-${day}c"

LF="$U/lock"
lock_acquire "$LF"
check "lock acquired" eq "$(cat "$LF")" "$$"
check "lock held by live pid blocks" bash -c 'source "$SCRIPT"; ! lock_acquire "$1"' _ "$LF"
lock_release "$LF"
check "lock released" test ! -e "$LF"
echo 999999 >"$LF"
check "stale lock reclaimed" bash -c 'source "$SCRIPT"; lock_acquire "$1" 2>/dev/null && [[ $(cat "$1") == $$ ]]' _ "$LF"
rm -f "$LF"

# ------------------------------------------------------------ end to end (stubbed)
echo "== e2e"
new_proj
deploy identifier-api "$NEW" --dry-run --local
check "dry-run rc 0" eq "$RC" 0
check "dry-run leaves versions.env" grep -q "IDENTIFIER_API_VERSION=$OLD" "$P/versions.env"
check "dry-run makes no backup" test -z "$(ls "$P" | grep 'bak-' || true)"
check "dry-run no compose up" bash -c '! grep -q "compose.* up " "$0"' "$STUB/calls"
check "dry-run prints plan" grep -q 'would set IDENTIFIER_API_VERSION' <<<"$OUT"

new_proj
deploy identifier "$NEW" --dry-run --local
check "alias identifier -> identifier-api" eq "$RC" 0

new_proj
deploy nonsense "$NEW" --local
check "unknown service rc 2" eq "$RC" 2
deploy identifier-api tooshort --local
check "bad sha rc 2" eq "$RC" 2
deploy all "$NEW" --local
check "'all' with explicit sha rc 2" eq "$RC" 2

new_proj
touch "$STUB/pre_bad"
deploy identifier-api "$NEW" --local
check "unhealthy-before aborts rc 2" eq "$RC" 2
check "unhealthy-before changes nothing" grep -q "IDENTIFIER_API_VERSION=$OLD" "$P/versions.env"

new_proj
touch "$STUB/compose_bad"
deploy identifier-api "$NEW" --local
check "invalid compose rc 2" eq "$RC" 2

new_proj
echo 'x' >"$P/.deploy.lock"
sleep 30 &
SP=$!
echo "$SP" >"$P/.deploy.lock"
deploy identifier-api "$NEW" --local
check "concurrent deploy rc 2" eq "$RC" 2
kill "$SP" 2>/dev/null
wait "$SP" 2>/dev/null

new_proj
deploy identifier-api "$NEW" --wait-image 0 --local
check "image missing rc 3" eq "$RC" 3
check "image missing message" grep -q 'IMAGE NOT PUBLISHED - nothing changed' <<<"$OUT"
check "image missing: versions.env untouched" grep -q "IDENTIFIER_API_VERSION=$OLD" "$P/versions.env"
check "image missing: no backup, no up" bash -c '[[ -z $(ls "$1" | grep bak- || true) ]] && ! grep -q "compose.* up " "$2"' _ "$P" "$STUB/calls"

new_proj
touch "$STUB/pull_ok"
deploy identifier-api "$NEW" --local
check "happy path rc 0" eq "$RC" 0
check "happy: version updated" grep -q "IDENTIFIER_API_VERSION=$NEW" "$P/versions.env"
check "happy: backup holds old" grep -q "IDENTIFIER_API_VERSION=$OLD" "$P"/versions.env.bak-*
check "happy: compose up --pull never --no-deps" grep -q 'up -d --no-deps --pull never identifier-api' "$STUB/calls"
check "happy: nginx reloaded" grep -q 'exec coachify-nginx-proxy nginx -s reload' "$STUB/calls"
check "happy: deploy.log line" grep -q "service=identifier-api old=$OLD new=$NEW result=OK" "$P/deploy.log"
check "happy: lock released" test ! -e "$P/.deploy.lock"

new_proj
touch "$STUB/pull_ok"
deploy frontend "$NEW" --local
check "frontend rc 0" eq "$RC" 0
check "frontend smoke /auth/signin w/ browser UA" grep -q 'Mozilla/5.0.*app.coachify.tn/auth/signin' "$STUB/calls"
check "frontend smoke /api/auth/providers" grep -q 'app.coachify.tn/api/auth/providers' "$STUB/calls"
new_proj
touch "$STUB/pull_ok"
deploy frontend "$NEW" --no-smoke --local
check "--no-smoke skips public smoke" bash -c '! grep -q "app.coachify.tn" "$0"' "$STUB/calls"

new_proj
touch "$STUB/pull_ok"
deploy identifier-api "$BAD" --local
check "bad new version -> rolled back rc 4" eq "$RC" 4
check "rollback message" grep -q "ROLLED BACK to $OLD" <<<"$OUT"
check "rollback restores versions.env" grep -q "IDENTIFIER_API_VERSION=$OLD" "$P/versions.env"
check "rollback logged" grep -q 'result=ROLLED BACK' "$P/deploy.log"

new_proj
touch "$STUB/pull_ok" "$STUB/log_panic"
deploy identifier-api "$NEW" --local
check "panic in logs -> rc 4" eq "$RC" 4
check "panic: versions restored" grep -q "IDENTIFIER_API_VERSION=$OLD" "$P/versions.env"

new_proj
touch "$STUB/pull_ok"
touch "$STUB/always_bad"
deploy identifier-api "$BAD" --force --local
check "rollback also unhealthy -> rc 5" eq "$RC" 5

new_proj
touch "$STUB/pull_ok"
deploy all latest-from-versions --dry-run --local
check "all dry-run rc 0" eq "$RC" 0
check "all dry-run lists all 12" eq "$(grep -c 'would set' <<<"$OUT")" 12
ORDER=$(grep -- "=== " <<<"$OUT" | sed -E 's/.*=== ([a-z-]+):.*/\1/' | tr '\n' ' ')
check "all dry-run order identifier first, frontend last" eq "$ORDER" "identifier-api notification-api content-api workout-api tracker-api statistics-api payments-api account-api invitation-api chat-api ai-api frontend "

new_proj
OUT=$(env PATH="$BIN:$PATH" STUB_DIR="$STUB" COACHIFY_DIR="$P" bash "$SCRIPT" identifier-api "$NEW" --dry-run --host me@example 2>&1)
RC=$?
check "remote mode: ssh used, rc 0" eq "$RC" 0
check "remote mode: runs --local --dry-run remotely" grep -q 'ssh .*me@example.*--local' "$STUB/calls"

echo
echo "passed=$PASS failed=$FAIL"
[[ $FAIL -eq 0 ]]
