#!/bin/bash
# setup-fail2ban.sh
# Installs fail2ban filters and jails that protect nginx from RFI probes,
# scanner bots, and repeated auth failures. Run once on a fresh VPS
# or re-run to update filter/jail definitions.
#
# Usage: sudo bash setup-fail2ban.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Ensure fail2ban is installed
# ---------------------------------------------------------------------------
if ! command -v fail2ban-client &>/dev/null; then
    echo "[setup-fail2ban] Installing fail2ban..."
    apt-get update -q && apt-get install -y fail2ban
fi

# ---------------------------------------------------------------------------
# 2. Resolve log paths from Docker volume mount
#    fail2ban will NOT start a jail if the logpath file does not exist.
#    Pre-touch the files so jails start even before nginx writes its first line.
# ---------------------------------------------------------------------------
LOG_DIR="/var/lib/docker/volumes/coachify_nginx_logs/_data"
mkdir -p "$LOG_DIR"
touch "$LOG_DIR/access_json.log"
touch "$LOG_DIR/blocked.log"
echo "[setup-fail2ban] Log files ready at $LOG_DIR"

# ---------------------------------------------------------------------------
# 3. RFI / script-extension probe filter
#    Reads access_json.log (the json_combined format written by nginx).
#    nginx format: {"time":"...","remote_addr":"1.2.3.4","method":"POST",
#                   "path":"/RSC/abc.txt","status":444,"agent":"zgrab/0.x",...}
#    Note: status is an UNQUOTED integer; agent field is "agent" not "http_user_agent".
# ---------------------------------------------------------------------------
cat > /etc/fail2ban/filter.d/nginx-rfi.conf << 'FILTER'
[Definition]
failregex = ^{.*"remote_addr":"<HOST>".*"path":"[^"]*\.(php|phtml|phar|sh|bash|py|pl|cgi|asp|aspx|jsp|cfm|txt|bak|sql)".*"status":[45][0-9][0-9][^0-9].*}$
            ^{.*"remote_addr":"<HOST>".*"path":"[^"]*(eval|base64_decode|passthru|system|exec|shell_exec|phpinfo)[^"]*".*"status":[45][0-9][0-9][^0-9].*}$
            ^{.*"remote_addr":"<HOST>".*"method":"POST".*"path":"/RSC/.*}$

ignoreregex =
datepattern = {json}%%Y-%%m-%%dT%%H:%%M:%%S
FILTER

# ---------------------------------------------------------------------------
# 4. Bad-bot / scanner filter
#    nginx if ($block_bot) returns 444. Those hits appear in access_json.log.
#    We match on status 444/403/400 combined with known bad UA substrings.
#    The "agent" field in json_combined maps to $http_user_agent.
#    Status is an UNQUOTED integer — do NOT wrap it in quotes in the regex.
# ---------------------------------------------------------------------------
cat > /etc/fail2ban/filter.d/nginx-bad-bots.conf << 'FILTER'
[Definition]
# Match scanner/bot user-agents that got 444/403/400 responses
failregex = ^{.*"remote_addr":"<HOST>".*"agent":"[^"]*(?:masscan|zgrab|nikto|sqlmap|nmap|dirbuster|gobuster|nuclei|censys|shodan|wpscan|python-requests|python-urllib|Go-http-client)[^"]*".*"status":(?:444|403|400)[^0-9].*}$
            ^{.*"remote_addr":"<HOST>".*"status":(?:444|403|400)[^0-9].*"agent":"".*}$

ignoreregex =
datepattern = {json}%%Y-%%m-%%dT%%H:%%M:%%S
FILTER

# ---------------------------------------------------------------------------
# 5. Jails
# ---------------------------------------------------------------------------
cat > /etc/fail2ban/jail.d/nginx-rfi.conf << 'JAIL'
[nginx-rfi]
enabled   = true
port      = http,https
filter    = nginx-rfi
logpath   = /var/lib/docker/volumes/coachify_nginx_logs/_data/access_json.log
maxretry  = 2
findtime  = 60
bantime   = 2592000
action    = iptables-multiport[name=nginx-rfi, port="http,https", protocol=tcp]
JAIL

cat > /etc/fail2ban/jail.d/nginx-bad-bots.conf << 'JAIL'
[nginx-bad-bots]
enabled   = true
port      = http,https
filter    = nginx-bad-bots
logpath   = /var/lib/docker/volumes/coachify_nginx_logs/_data/access_json.log
maxretry  = 2
findtime  = 30
bantime   = 2592000
action    = iptables-multiport[name=nginx-bad-bots, port="http,https", protocol=tcp]
JAIL

# ---------------------------------------------------------------------------
# 6. Reload fail2ban
# ---------------------------------------------------------------------------
systemctl enable fail2ban
systemctl restart fail2ban

sleep 2   # give fail2ban time to load jails before querying status

echo ""
echo "[setup-fail2ban] Done. Active jails:"
fail2ban-client status

echo ""
echo "[setup-fail2ban] To ban an IP manually:"
echo "  sudo fail2ban-client set nginx-rfi banip <IP>"
echo "  sudo fail2ban-client set nginx-bad-bots banip <IP>"
echo ""
echo "[setup-fail2ban] To test a filter against the live log:"
echo "  sudo fail2ban-regex $LOG_DIR/access_json.log /etc/fail2ban/filter.d/nginx-bad-bots.conf"
