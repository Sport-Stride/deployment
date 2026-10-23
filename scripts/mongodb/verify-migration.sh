#!/usr/bin/env bash
# =============================================================================
# verify-migration.sh - compare LOCAL MongoDB with the MANAGED cluster.
# Read-only on both sides. For every database / collection it compares:
#   - collection presence, type (collection/view/timeseries), capped options
#   - document counts (countDocuments)
#   - index names + definitions (key order, unique, sparse, partial, collation,
#     expireAfterSeconds ...)
#   - sampled content checksum: $sample N docs (default 1000) from LOCAL, fetch
#     the same _ids from MANAGED, hash the canonical EJSON of both sets
# TTL collections: count/sample differences are WARN (the TTL monitor deletes
# in the background on both sides). Capped collections must match exactly.
# --allow-drift (use in --rehearsal while the app still writes): count and
# sample differences become WARN; index/option/presence differences still FAIL.
#
# The URI is never printed; output is masked. Credentials via env/file, see
# preflight-managed.sh (NEW_URI env or $MANAGED_ENV; local password from env files).
#
# Usage: NEW_URI=... ./verify-migration.sh [--dbs a,b] [--sample N] [--allow-drift] [--env-file F]
# Exit: 0 identical | 1 mismatch | 2 usage/config error
# =============================================================================
set -euo pipefail

DIR="${COACHIFY_DIR:-$HOME/production/coachify}"
ENV_FILE="${ENV_FILE:-$DIR/.env.production}"
MANAGED_ENV="${MANAGED_ENV:-$DIR/.managed-db.env}"
TOOLS_IMAGE="${TOOLS_IMAGE:-mongo:7}"
LOCAL_CTR="${LOCAL_CTR:-coachify-mongodb}"
TOOLS_MEM="${TOOLS_MEM:-384m}"
DEFAULT_DBS="COACHIFY CONTENT identifier statistics_read statistics_write users workout-management"
DBS_OVERRIDE=""
SAMPLE=1000
ALLOW_DRIFT=false
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

gen_js() { # $1=db list (space sep)
  local dbs="" d lu
  lu=$(local_uri) || die "local root password not found (LOCAL_MONGO_ROOT_PASSWORD in env or $ENV_FILE)"
  for d in $1; do dbs+="$(jsq "$d"),"; done
  {
    printf 'const LOCAL_URI = %s;\nconst NEW_URI = %s;\nconst DBS = [%s];\nconst SAMPLE = %s;\nconst ALLOW_DRIFT = %s;\n' \
      "$(jsq "$lu")" "$(jsq "$NEW_URI")" "$dbs" "$SAMPLE" "$ALLOW_DRIFT"
    cat <<'JS'
let nFail = 0, nWarn = 0, nOk = 0;
function line(st, ns, d) {
  if (st === "FAIL") nFail++; else if (st === "WARN") nWarn++; else nOk++;
  print("LINE\t" + st + "\t" + ns + "\t" + (d || ""));
}
function h32(s, seed) { let h = seed >>> 0; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; } return h; }
function hash(s) { return h32(s, 2166136261).toString(16).padStart(8, "0") + h32(s, 0x9747b28c).toString(16).padStart(8, "0"); }
function num(d) { return (d !== null && typeof d === "object" && typeof d.valueOf === "function") ? Number(d.valueOf()) : d; }
function canonIdx(ix) {
  const { key, v, ns, background, ...rest } = ix;
  const k = Object.entries(key).map(([f, d]) => [f, num(d)]);
  const r = {}; Object.keys(rest).sort().forEach(x => { r[x] = rest[x]; });
  return JSON.stringify(k) + EJSON.stringify(r, { relaxed: true });
}
function idxMap(coll) { const m = new Map(); coll.getIndexes().forEach(ix => m.set(ix.name, canonIdx(ix))); return m; }
function infos(db) { const m = new Map(); db.getCollectionInfos({}).forEach(i => { if (!i.name.startsWith("system.")) m.set(i.name, i); }); return m; }
function opt(i, k) { return i.options ? i.options[k] : undefined; }
function ttlOf(ixm) { for (const c of ixm.values()) if (c.includes("expireAfterSeconds")) return true; return false; }

let L, N;
try { L = new Mongo(LOCAL_URI); N = new Mongo(NEW_URI); L.getDB("admin").runCommand({ ping: 1 }); N.getDB("admin").runCommand({ ping: 1 }); }
catch (e) { print("LINE\tFAIL\tconnect\t" + String(e.message || e).split("\n")[0].slice(0, 160)); print("SUMMARY\t1\t0\t0"); quit(1); }

for (const dbn of DBS) {
  let ld = L.getDB(dbn), nd = N.getDB(dbn), li, ni;
  try { li = infos(ld); ni = infos(nd); } catch (e) { line("FAIL", dbn, "cannot list collections: " + String(e.message).slice(0, 120)); continue; }
  for (const n of ni.keys()) if (!li.has(n)) line("FAIL", dbn + "." + n, "exists on MANAGED only (stale; restore with --drop does not remove extras)");
  for (const [name, a] of li) {
    const ns = dbn + "." + name, b = ni.get(name), tags = [];
    if (!b) { line("FAIL", ns, "missing on MANAGED"); continue; }
    if (a.type !== b.type) { line("FAIL", ns, "type local=" + a.type + " managed=" + b.type); continue; }
    if (a.type === "view") {
      const same = opt(a, "viewOn") === opt(b, "viewOn") && EJSON.stringify(opt(a, "pipeline") || []) === EJSON.stringify(opt(b, "pipeline") || []);
      line(same ? "OK" : "FAIL", ns, "view" + (same ? "" : " definition differs"));
      continue;
    }
    const capped = !!opt(a, "capped"), ts = a.type === "timeseries";
    if (capped) {
      tags.push("capped");
      if (!opt(b, "capped") || Number(opt(a, "size")) !== Number(opt(b, "size")) || Number(opt(a, "max") || 0) !== Number(opt(b, "max") || 0)) { line("FAIL", ns, "capped options differ (local size=" + opt(a, "size") + " max=" + opt(a, "max") + ")"); continue; }
    }
    if (ts) tags.push("timeseries");
    const lc = ld.getCollection(name), nc = nd.getCollection(name);
    let st = "OK"; const msgs = [];
    const bump = (s, m) => { if (s === "FAIL" || (s === "WARN" && st === "OK")) st = s; msgs.push(m); };
    // indexes
    let lx, nx;
    try { lx = idxMap(lc); nx = idxMap(nc); } catch (e) { line("FAIL", ns, "getIndexes: " + String(e.message).slice(0, 100)); continue; }
    const ttl = ttlOf(lx); if (ttl) tags.push("ttl");
    if (lx.size !== nx.size) bump("FAIL", "index count local=" + lx.size + " managed=" + nx.size);
    for (const [n, c] of lx) {
      if (!nx.has(n)) bump("FAIL", "index " + n + " missing on managed");
      else if (nx.get(n) !== c) bump("FAIL", "index " + n + " definition differs");
    }
    for (const n of nx.keys()) if (!lx.has(n)) bump("FAIL", "index " + n + " extra on managed");
    // counts
    const drift = ALLOW_DRIFT || ttl;
    let lcnt, ncnt;
    try { lcnt = lc.countDocuments({}); ncnt = nc.countDocuments({}); } catch (e) { line("FAIL", ns, "count: " + String(e.message).slice(0, 100)); continue; }
    if (lcnt !== ncnt) bump(drift ? "WARN" : "FAIL", "docs local=" + lcnt + " managed=" + ncnt + (ttl ? " (ttl expiry)" : ""));
    // sampled content checksum
    let sm = "skipped";
    if (lcnt > 0 && !ts) {
      try {
        const ids = lc.aggregate([{ $sample: { size: SAMPLE } }, { $project: { _id: 1 } }]).toArray().map(d => d._id);
        const grab = c => { const m = new Map(); c.find({ _id: { $in: ids } }).forEach(d => m.set(EJSON.stringify(d._id, { relaxed: false }), EJSON.stringify(d, { relaxed: false }))); return m; };
        const A = grab(lc), B = grab(nc), keys = [...A.keys()].sort();
        let miss = 0, diff = 0, ha = "";
        for (const k of keys) { ha += A.get(k); if (!B.has(k)) miss++; else if (B.get(k) !== A.get(k)) diff++; }
        sm = ids.length + "/" + hash(ha);
        if (miss || diff) bump(drift ? "WARN" : "FAIL", "sample " + ids.length + ": missing=" + miss + " different=" + diff);
      } catch (e) { bump("WARN", "sample skipped: " + String(e.message).slice(0, 80)); }
    }
    line(st, ns, "docs=" + lcnt + " idx=" + lx.size + " sample=" + sm + (tags.length ? " [" + tags.join(",") + "]" : "") + (msgs.length ? " | " + msgs.join("; ") : ""));
  }
}
print("SUMMARY\t" + nFail + "\t" + nWarn + "\t" + nOk);
quit(nFail ? 1 : 0);
JS
  } >"$TMP/verify.js"
}

main() {
  while (($#)); do
    case $1 in
      --dbs) DBS_OVERRIDE=${2:-}; shift 2 ;;
      --sample) SAMPLE=${2:-}; shift 2 ;;
      --allow-drift) ALLOW_DRIFT=true; shift ;;
      --env-file) ENV_FILE=${2:-}; shift 2 ;;
      -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ $SAMPLE =~ ^[0-9]+$ && $SAMPLE -ge 1 ]] || die "--sample needs a positive integer"
  command -v docker >/dev/null || die "docker not found (run on the server)"
  TMP=$(umask 077; mktemp -d); trap cleanup EXIT
  load_new_uri
  NET=$(net_of); [[ -n $NET ]] || die "container $LOCAL_CTR not found / no network (set LOCAL_CTR)"

  local dbs
  if [[ -n $DBS_OVERRIDE ]]; then dbs=${DBS_OVERRIDE//,/ }
  else dbs=$(discover_dbs | tr '\n' ' ') || true; [[ -n ${dbs// /} ]] || dbs=$DEFAULT_DBS; fi
  echo "== verify local ($LOCAL_CTR) vs managed ($(uri_host "$NEW_URI")) =="
  echo "databases: $dbs | sample=$SAMPLE | allow-drift=$ALLOW_DRIFT"
  gen_js "$dbs"

  local out rc=0 tag st ns det f=0 w=0 o=0
  out=$(tool_run -c 'mongosh --nodb --quiet --file /cfg/verify.js' 2>&1) || rc=$?
  while IFS=$'\t' read -r tag st ns det; do
    case $tag in
      LINE) printf '[%-4s] %-42s %s\n' "$st" "$ns" "$det" | redact ;;
      SUMMARY) f=$st; w=$ns; o=$det ;;
      "") ;;
      *) printf '       %s\n' "$tag" | redact ;;
    esac
  done <<<"$out"
  echo "----"
  if ((f > 0 || (rc != 0 && o == 0))); then echo "VERIFY: FAIL (fail=$f warn=$w ok=$o rc=$rc)"; exit 1; fi
  echo "VERIFY: PASS (fail=0 warn=$w ok=$o)"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
