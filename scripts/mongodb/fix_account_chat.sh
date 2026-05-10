#!/usr/bin/env bash
# Force-recreate account-api and chat-api with --pull never so the
# registry auth error doesn't prevent container recreation.
# MONGODB_URI comes from env_file (.env.production) for these services —
# no shell env injection needed.
set -e
COMPOSE_FILE=/home/deploy/production/coachify/docker-compose.prod.yml
cd /home/deploy/production/coachify

echo "=== Recreating account-api ==="
docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate --pull never account-api

echo "=== Recreating chat-api ==="
docker compose -f "$COMPOSE_FILE" up -d --no-deps --force-recreate --pull never chat-api

echo "=== Waiting 30s for services to start ==="
sleep 30

echo "=== Container status ==="
docker inspect --format='{{.Name}} MONGODB_URI={{range .Config.Env}}{{if and (gt (len .) 11) (eq (slice . 0 11) "MONGODB_URI")}}{{.}}{{end}}{{end}} status={{.State.Health.Status}}' \
  coachify-account-api coachify-chat-api 2>/dev/null || true

echo "=== account-api logs ==="
docker logs --tail=10 coachify-account-api 2>&1

echo "=== chat-api logs ==="
docker logs --tail=10 coachify-chat-api 2>&1
