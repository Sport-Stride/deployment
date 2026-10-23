#!/usr/bin/env bash
# =============================================================================
# preflight-managed.sh - read-only readiness check of the MANAGED MongoDB
# (Atlas) cluster, run FROM THE PRODUCTION SERVER before any migration.
#
# Checks (via a throwaway mongo:7 container on the compose network):
#   1 DNS + TLS + connect      2 authentication      3 server version >= local
#   4 latency (20 pings, p50/p95)   5 readWrite on every needed database
#   6 what already exists on the target (informational)
#
# The URI is NEVER printed. All output is passed through a masking filter.
#
# Input (first match wins):
#   NEW_URI env var | NEW_URI= line in $MANAGED_ENV (default
#   ~/production/coachify/.managed-db.env, chmod 600; NOT .env.production,
#   because compose env_file would hand it to every container).
# Local password (only used to discover DB names / local version):
#   LOCAL_MONGO_ROOT_PASSWORD env or in .env.production / .env.
#
# Usage: NEW_URI=... ./preflight-managed.sh [--dbs a,b,c] [--env-file F]
# Exit: 0 all PASS (WARN allowed) | 1 at least one FAIL | 2 usage/config error
# =============================================================================
set -euo pipefail

DIR="${COACHIFY_DIR:-$HOME/production/coachify}"
ENV_FILE="${ENV_FILE:-$DIR/.env.production}"
MANAGED_ENV="${MANAGED_ENV:-$DIR/.managed-db.env}"
TOOLS_IMAGE="${TOOLS_IMAGE:-mongo:7}"
LOCAL_CTR="${LOCAL_CTR:-coachify-mongodb}"
TOOLS_MEM="${TOOLS_MEM:-256m}"
DEFAULT_DBS="COACHIFY CONTENT identifier statistics_read statistics_write users workout-management"
LAT_WARN_MS="${LAT_WARN_MS:-80}"
LAT_FAIL_MS="${LAT_FAIL_MS:-250}"
DBS_OVERRIDE=""
SECRETS=()
TMP=""

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

gen_js() { # $1=db list (space sep) $2=local version
  local dbs="" d
  for d in $1; do dbs+="$(jsq "$d"),"; done
  {
    printf 'const NEW_URI = %s;\nconst NEEDED = [%s];\nconst LOCAL_VER = %s;\nconst LAT_WARN = %s, LAT_FAIL = %s;\n' \
      "$(jsq "$NEW_URI")" "$dbs" "$(jsq "$2")" "$LAT_WARN_MS" "$LAT_FAIL_MS"
    cat <<'JS'
function res(n, s, d) { print("RESULT\t" + n + "\t" + s + "\t" + (d || "")); }
function classify(e) {
  const m = String((e && e.message) || e);
  if (/querySrv|ENOTFOUND|getaddrinfo|EAI_AGAIN|ENODATA/i.test(m)) return "DNS resolution failed (check cluster hostname / server DNS)";
  if (/certificate|SSL|TLS|handshake|ssl3/i.test(m)) return "TLS error (cert chain / clock / tls options)";
  if (/Authentication failed|bad auth|AuthenticationFailed|auth failed/i.test(m)) return "authentication failed (user/password/authSource)";
  if (/selection timed out|ETIMEDOUT|ECONNREFUSED|ECONNRESET|timed out|Could not connect/i.test(m)) return "network timeout/refused (Atlas IP access list must contain the server public IP)";
  return "other: " + m.split("\n")[0].slice(0, 160);
}
function vcmp(a, b) {
  const x = a.split(".").map(Number), y = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) { if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) - (y[i] || 0); }
  return 0;
}
let conn, adm;
try {
  conn = new Mongo(NEW_URI);
  adm = conn.getDB("admin");
  const h = adm.runCommand({ hello: 1 });
  res("connect/dns/tls", "PASS", "topology=" + (h.setName ? "replicaset" : "standalone") + " writablePrimary=" + h.isWritablePrimary);
} catch (e) { res("connect/dns/tls", "FAIL", classify(e)); quit(1); }

// authentication
let cs = null;
try {
  cs = adm.runCommand({ connectionStatus: 1, showPrivileges: true });
  const u = (cs.authInfo.authenticatedUsers || []);
  if (u.length) res("authentication", "PASS", "authenticated as " + u[0].user.slice(0, 3) + "*** roles=" + (cs.authInfo.authenticatedUserRoles || []).map(r => r.role + "@" + r.db).join(","));
  else res("authentication", "FAIL", "connected but no authenticated user (credentials missing in URI?)");
} catch (e) { res("authentication", "FAIL", classify(e)); }

// version
try {
  const v = adm.runCommand({ buildInfo: 1 }).version;
  const c = vcmp(v, LOCAL_VER);
  if (c < 0) res("server-version", "FAIL", "managed " + v + " < local " + LOCAL_VER);
  else if (v.split(".")[0] !== LOCAL_VER.split(".")[0]) res("server-version", "WARN", "managed " + v + " newer major than local " + LOCAL_VER + " (Go driver 1.17.x supports up to 8.0; review release notes)");
  else res("server-version", "PASS", "managed " + v + " local " + LOCAL_VER);
} catch (e) { res("server-version", "FAIL", classify(e)); }

// latency
try {
  const now = () => (typeof process !== "undefined" && process.hrtime) ? Number(process.hrtime.bigint()) / 1e6 : Date.now();
  adm.runCommand({ ping: 1 });
  const t = [];
  for (let i = 0; i < 20; i++) { const s = now(); adm.runCommand({ ping: 1 }); t.push(now() - s); }
  t.sort((a, b) => a - b);
  const p50 = t[Math.floor(t.length * 0.5)], p95 = t[Math.ceil(t.length * 0.95) - 1];
  const st = p50 > LAT_FAIL ? "FAIL" : (p50 > LAT_WARN ? "WARN" : "PASS");
  res("latency", st, "p50=" + p50.toFixed(1) + "ms p95=" + p95.toFixed(1) + "ms min=" + t[0].toFixed(1) + "ms (n=20, warn>" + LAT_WARN + " fail>" + LAT_FAIL + " p50)");
} catch (e) { res("latency", "FAIL", classify(e)); }

// readWrite on needed DBs
try {
  if (!cs) cs = adm.runCommand({ connectionStatus: 1, showPrivileges: true });
  const roles = cs.authInfo.authenticatedUserRoles || [];
  const privs = cs.authInfo.authenticatedUserPrivileges || [];
  const need = ["find", "insert", "update", "remove", "createIndex", "listIndexes", "createCollection", "dropCollection"];
  const bad = [];
  for (const db of NEEDED) {
    const byRole = roles.some(r => (r.db === db && ["readWrite", "dbOwner"].includes(r.role)) ||
      (r.db === "admin" && ["readWriteAnyDatabase", "dbOwner", "root", "atlasAdmin"].includes(r.role)));
    const acts = new Set();
    privs.forEach(p => {
      const r = p.resource || {};
      if (r.anyResource || ((r.db === db || r.db === "") && (r.collection === "" || r.collection === undefined))) (p.actions || []).forEach(a => acts.add(a));
    });
    const byPriv = need.every(a => acts.has(a));
    if (!byRole && !byPriv) bad.push(db);
  }
  if (bad.length) res("readWrite-on-dbs", "FAIL", "missing readWrite on: " + bad.join(","));
  else res("readWrite-on-dbs", "PASS", NEEDED.length + " databases: " + NEEDED.join(","));
} catch (e) { res("readWrite-on-dbs", "FAIL", classify(e)); }

// target state
try {
  const have = adm.runCommand({ listDatabases: 1, nameOnly: true, authorizedDatabases: true }).databases.map(d => d.name);
  const info = NEEDED.filter(n => have.includes(n)).map(n => n + "=" + conn.getDB(n).getCollectionNames().length + "coll");
  res("target-state", "INFO", info.length ? "already present: " + info.join(" ") + " (--drop will overwrite)" : "none of the needed DBs exist yet (clean target)");
} catch (e) { res("target-state", "WARN", classify(e)); }
JS
  } >"$TMP/preflight.js"
}

main() {
  while (($#)); do
    case $1 in
      --dbs) DBS_OVERRIDE=${2:-}; shift 2 ;;
      --env-file) ENV_FILE=${2:-}; shift 2 ;;
      -h | --help) sed -n '2,25p' "$0"; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  command -v docker >/dev/null || die "docker not found (run on the server)"
  TMP=$(umask 077; mktemp -d); trap cleanup EXIT
  load_new_uri
  NET=$(net_of); [[ -n $NET ]] || die "container $LOCAL_CTR not found / no network (set LOCAL_CTR)"

  local ver dbs
  ver=$(docker exec "$LOCAL_CTR" mongod --version 2>/dev/null | sed -n 's/^db version v//p' | head -1) || true
  [[ -n $ver ]] || die "cannot read local mongod version from $LOCAL_CTR"
  if [[ -n $DBS_OVERRIDE ]]; then dbs=${DBS_OVERRIDE//,/ }
  else dbs=$(discover_dbs | tr '\n' ' ') || true; [[ -n ${dbs// /} ]] || dbs=$DEFAULT_DBS; fi

  echo "== managed MongoDB preflight =="
  echo "target : $(uri_host "$NEW_URI") (user $(uri_user "$NEW_URI"))"
  echo "local  : $LOCAL_CTR v$ver | databases: $dbs"
  echo "image  : $TOOLS_IMAGE (pulled if absent)"
  gen_js "$dbs" "$ver"

  local out rc=0 fails=0 warns=0 name st det
  out=$(tool_run -c 'mongosh --nodb --quiet --file /cfg/preflight.js' 2>&1) || rc=$?
  while IFS=$'\t' read -r tag name st det; do
    if [[ $tag == RESULT ]]; then
      case $st in FAIL) fails=$((fails + 1)) ;; WARN) warns=$((warns + 1)) ;; esac
      printf '[%-4s] %-18s %s\n' "$st" "$name" "$det" | redact
    elif [[ -n $tag ]]; then
      printf '       %s\n' "$tag${name:+ $name}" | redact
    fi
  done <<<"$out"
  [[ $rc -ne 0 && $fails -eq 0 ]] && { echo "[FAIL] container exited with $rc and reported no result"; fails=1; }
  echo "----"
  if ((fails)); then echo "PREFLIGHT: FAIL ($fails failed, $warns warnings)"; exit 1; fi
  echo "PREFLIGHT: PASS ($warns warnings)"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
