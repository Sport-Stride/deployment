#!/usr/bin/env bash
# Grant coachifyApp readWriteAnyDatabase so all microservices can use their own databases
set -e

ADMIN_USER='adminUser'
ADMIN_PASS='SportStride2026!'
ENCODED_PASS=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${ADMIN_PASS}', safe=''))")
ADMIN_URI="mongodb://${ADMIN_USER}:${ENCODED_PASS}@127.0.0.1:27017/admin?authSource=admin"

echo "=== Current databases ==="
mongosh --quiet "${ADMIN_URI}" --eval "db.adminCommand({ listDatabases: 1 }).databases.map(d => d.name)" | head -20

echo "=== Granting coachifyApp readWriteAnyDatabase ==="
mongosh --quiet "${ADMIN_URI}" --eval "
db.getSiblingDB('coachify').grantRolesToUser('coachifyApp', [
  { role: 'readWriteAnyDatabase', db: 'admin' }
]);
print('Done');
"

echo "=== Verifying current coachifyApp roles ==="
mongosh --quiet "${ADMIN_URI}" --eval "JSON.stringify(db.getSiblingDB('coachify').getUser('coachifyApp').roles)"
