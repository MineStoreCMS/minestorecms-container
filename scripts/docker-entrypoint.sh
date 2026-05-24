#!/bin/bash
# MineStoreCMS container entrypoint — idempotent, runs every start.

set -euo pipefail

APP=/var/www/minestore
ENVDIR=/var/lib/minestore-env
DEFAULTS=/opt/minestore-defaults
PHP=/usr/bin/php8.3

# 1. Wait for DB
echo "[entrypoint] Waiting for database at ${DB_HOST}:${DB_PORT} ..."
for i in $(seq 1 60); do
    # Credentials read via getenv inside PHP so shell-special chars in DB_PASSWORD
    # cannot break the inline argument.
    if $PHP -r 'try { new PDO("mysql:host=".getenv("DB_HOST").";port=".getenv("DB_PORT"), getenv("DB_USERNAME"), getenv("DB_PASSWORD")); exit(0); } catch (\Throwable $e) { exit(1); }' 2>/dev/null; then
        echo "[entrypoint] Database reachable."
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "[entrypoint] Database not reachable after 120s — exiting." >&2
        exit 1
    fi
    sleep 2
done

# 2. Seed .env if missing
#
# Strategy: copy .env.example to capture defaults, then APPEND container-mode
# overrides. Laravel's dotenv parser uses last-write-wins per key, so the
# appended overrides take precedence. Using a heredoc instead of sed avoids
# the shell-injection / sed-special-char issues that arise when env values
# contain `|`, `&`, `\`, `/`, `$`, etc.
mkdir -p "$ENVDIR"
if [ ! -f "$ENVDIR/.env" ]; then
    echo "[entrypoint] Seeding .env from defaults ..."
    cp "$DEFAULTS/.env.example" "$ENVDIR/.env"
    {
        printf '\n# Container overrides — set by docker-entrypoint.sh\n'
        printf 'APP_URL=%s\n'      "${APP_URL}"
        printf 'APP_ENV=%s\n'      "${APP_ENV:-production}"
        printf 'APP_DEBUG=%s\n'    "${APP_DEBUG:-false}"
        printf 'LICENSE_KEY=%s\n'  "${LICENSE_KEY}"
        printf 'TIMEZONE=%s\n'     "${TIMEZONE:-UTC}"
        printf 'LOCALE=%s\n'       "${LOCALE:-en}"
        printf 'DB_HOST=%s\n'      "${DB_HOST}"
        printf 'DB_PORT=%s\n'      "${DB_PORT}"
        printf 'DB_DATABASE=%s\n'  "${DB_DATABASE}"
        printf 'DB_USERNAME=%s\n'  "${DB_USERNAME}"
        printf 'DB_PASSWORD=%s\n'  "${DB_PASSWORD}"
        printf 'INSTALL_MODE=docker\n'
    } >> "$ENVDIR/.env"
    rm -f "$APP/.env"
    ln -sf "$ENVDIR/.env" "$APP/.env"
    $PHP "$APP/artisan" key:generate --force
else
    rm -f "$APP/.env"
    ln -sf "$ENVDIR/.env" "$APP/.env"
fi

# 3. Seed frontend volume if empty
if [ ! -f "$APP/frontend/package.json" ]; then
    echo "[entrypoint] Seeding frontend from defaults ..."
    mkdir -p "$APP/frontend"
    cp -a "$DEFAULTS/frontend/." "$APP/frontend/"
fi

# 4. Permissions
chown -R www-data:www-data "$APP"
chmod -R u+rwX,g+rwX "$APP/storage" "$APP/bootstrap/cache" "$APP/public/img" "$APP/public/assets" || true
chmod 640 "$APP/.env" || true

# 5. Migrate (idempotent)
echo "[entrypoint] Running migrations ..."
cd "$APP"
$PHP artisan migrate --force || true

# 5b. Run pending upgrade hooks (idempotent — tracked in upgrade_runs table)
#     Catches per-version operations that don't fit inside a Laravel migration
#     (one-off reindex jobs, file moves, etc). Failures are logged but do NOT
#     abort startup — supervisord still comes up so the app is reachable for
#     debugging.
echo "[entrypoint] Running pending upgrade hooks ..."
$PHP artisan app:run-pending-upgrades || \
    echo "[entrypoint] WARNING: one or more upgrade hooks failed (see logs above)"

# 6. Cache config/route/view
$PHP artisan config:clear
$PHP artisan config:cache
$PHP artisan route:cache || true
$PHP artisan view:cache || true

# 7. Build frontend if needed
HASH_FILE="$APP/frontend/.minestore-build-hash"
CURRENT_HASH=$(sha256sum "$APP/frontend/package.json" 2>/dev/null | cut -d' ' -f1)
PREV_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")
if [ ! -d "$APP/frontend/.next" ] || [ "$CURRENT_HASH" != "$PREV_HASH" ]; then
    echo "[entrypoint] Building frontend (hash changed or no .next) ..."
    cd "$APP/frontend"
    pnpm install --prefer-offline --no-frozen-lockfile
    pnpm run build
    echo "$CURRENT_HASH" > "$HASH_FILE"
fi

# 8. Hand off to supervisord
echo "[entrypoint] Starting supervisord ..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
