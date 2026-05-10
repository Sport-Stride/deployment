#!/usr/bin/env bash
set -euo pipefail

echo "=== Disabling auth temporarily ==="
sed -i 's/authorization: enabled/authorization: disabled/' /etc/mongod.conf
systemctl restart mongod
sleep 3

echo "=== Admin users ==="
mongosh --quiet --host 127.0.0.1 --port 27017 /tmp/check_users.js

echo "=== Re-enabling auth ==="
sed -i 's/authorization: disabled/authorization: enabled/' /etc/mongod.conf
systemctl restart mongod
sleep 3
echo "=== Done, mongod auth re-enabled ==="
