#!/bin/bash
# End-to-end smoke test for the docker install path.
# Requires: LICENSE_KEY env var, a host with docker + DNS for $SMOKE_DOMAIN
# (or /etc/hosts entry), and a free port (set SMOKE_PORT, default 18099).

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
NAME="${SMOKE_NAME:-smoke}"
DOMAIN="${SMOKE_DOMAIN:-smoke.localtest.me}"
PORT="${SMOKE_PORT:-18099}"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

[ -n "${LICENSE_KEY:-}" ] || { echo "LICENSE_KEY required." >&2; exit 1; }

DIR="$ROOT/$NAME"
mkdir -p "$DIR"

cat > "$DIR/.env" <<EOF
INSTANCE_NAME=$NAME
LICENSE_KEY=$LICENSE_KEY
APP_DOMAIN=$DOMAIN
APP_URL=http://$DOMAIN:$PORT
APP_ENV=local
APP_DEBUG=true
TIMEZONE=UTC
LOCALE=en
DB_DATABASE=minestore
DB_USERNAME=minestore
DB_PASSWORD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
HTTP_PORT=$PORT
REPO_PATH=$REPO
EOF

INSTANCE_NAME=$NAME LICENSE_KEY=$LICENSE_KEY \
APP_URL="http://$DOMAIN:$PORT" HTTP_PORT=$PORT \
DB_PASSWORD=$(grep DB_PASSWORD "$DIR/.env" | cut -d= -f2) \
DB_USERNAME=minestore DB_DATABASE=minestore REPO_PATH=$REPO \
    envsubst < "$REPO/docker-compose.yaml.template" > "$DIR/docker-compose.yaml"

cd "$DIR"
docker compose -p "minestore-$NAME" build
docker compose -p "minestore-$NAME" up -d

echo "Waiting for healthy state ..."
for i in $(seq 1 120); do
    state=$(docker inspect --format '{{json .State.Health.Status}}' "minestore-$NAME-app" 2>/dev/null || echo '""')
    [ "$state" = '"healthy"' ] && break
    sleep 5
done

echo "Hitting /api/health:"
curl -fsS "http://127.0.0.1:$PORT/api/health" | tee /dev/stderr

docker compose -p "minestore-$NAME" down -v
echo "Smoke test passed."
