set -e
js_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}
esc_user="$(js_escape "adminUser")"
esc_pass="$(js_escape "SportStride2026!")"
tmp="$(mktemp /tmp/.mongo-XXXXXXXX.js)"
chmod 600 "$tmp"
printf '%s\n' "
  var _ok = db.getSiblingDB(\"admin\").auth(\"${esc_user}\", \"${esc_pass}\");
  if (!_ok) { throw new Error(\"Auth failed\"); }
  var r = db.adminCommand(\"ping\");
  print(\"ping result:\", JSON.stringify(r));
" > "$tmp"
echo "=== File contents ==="
cat "$tmp"
echo "=== Running mongosh ==="
mongosh --quiet --host 127.0.0.1 --port 27017 "$tmp"
rm -f "$tmp"
