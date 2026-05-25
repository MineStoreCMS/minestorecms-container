#!/bin/bash
# MineStoreCMS container entrypoint — idempotent, runs every start.

set -euo pipefail

APP=/var/www/minestore
ENVDIR=/var/lib/minestore-env
DEFAULTS=/opt/minestore-defaults
PHP=/usr/bin/php8.3

# 0. Fail fast with a readable message when a required env var is missing.
: "${LICENSE_KEY:?LICENSE_KEY is required (set in compose env or .env)}"
: "${DB_HOST:?DB_HOST is required}"
: "${DB_PORT:?DB_PORT is required}"
: "${DB_DATABASE:?DB_DATABASE is required}"
: "${DB_USERNAME:?DB_USERNAME is required}"
: "${DB_PASSWORD:?DB_PASSWORD is required}"
: "${APP_URL:?APP_URL is required}"

# 0b. Sanity-check the MineStore
EXT_DIR=$($PHP -r 'echo ini_get("extension_dir");')
TZ_SO="$EXT_DIR/timezone.so"
if [ ! -f "$TZ_SO" ]; then
    echo "[entrypoint] FATAL: $TZ_SO missing — rebuild image (loader was not copied from tarball)" >&2
    exit 1
fi
if ! $PHP -r 'exit(function_exists("zval_zone") ? 0 : 1);' 2>/dev/null; then
    echo "[entrypoint] FATAL: timezone.so loaded but zval_zone() unavailable — loader/blob mismatch" >&2
    exit 1
fi
echo "[entrypoint] timezone loader OK ($(stat -c %s "$TZ_SO") bytes at $TZ_SO)"

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

# 2a. Create storage/cache scaffolding BEFORE any artisan command.
mkdir -p \
    "$APP/storage/framework/views" \
    "$APP/storage/framework/cache/data" \
    "$APP/storage/framework/sessions" \
    "$APP/storage/framework/testing" \
    "$APP/storage/logs" \
    "$APP/storage/app/public" \
    "$APP/bootstrap/cache"
chown -R www-data:www-data "$APP/storage" "$APP/bootstrap/cache"
chmod -R u+rwX,g+rwX "$APP/storage" "$APP/bootstrap/cache"

# 2b. Seed .env if missing
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

# 4. Permissions on volume-backed directories that need www-data write access.
chown -R www-data:www-data \
    "$APP/storage" "$APP/bootstrap/cache" \
    "$APP/public/img" "$APP/public/assets" 2>/dev/null || true
chmod -R u+rwX,g+rwX \
    "$APP/storage" "$APP/bootstrap/cache" \
    "$APP/public/img" "$APP/public/assets" 2>/dev/null || true
chmod 640 "$APP/.env" 2>/dev/null || true

# 5. Migrate
echo "[entrypoint] Running migrations ..."
cd "$APP"
if ! $PHP artisan migrate --force; then
    echo "[entrypoint] WARNING: migrations FAILED — DB schema may be inconsistent." >&2
    echo "[entrypoint]          App will keep starting; check 'minestore logs' and re-run" >&2
    echo "[entrypoint]          'minestore artisan <name> migrate --force' once the issue is fixed." >&2
fi

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
    # pnpm 10+ exits non-zero when new deps ship unapproved build scripts
    if ! pnpm install --prefer-offline --no-frozen-lockfile; then
        echo "[entrypoint] pnpm install failed — running 'pnpm approve-builds' and retrying"
        yes | pnpm approve-builds || true
        pnpm install --prefer-offline --no-frozen-lockfile
    fi
    pnpm run build
    echo "$CURRENT_HASH" > "$HASH_FILE"
fi

# 8. Export SERVER_NAME for CLI workers (queue/cron/discord/scheduler).
SERVER_NAME=$(printf '%s' "$APP_URL" | sed -E 's,^[a-zA-Z]+://([^/:]+).*,\1,')
if [ -z "$SERVER_NAME" ] || [ "$SERVER_NAME" = "$APP_URL" ]; then
    echo "[entrypoint] FATAL: could not extract hostname from APP_URL='$APP_URL'" >&2
    exit 1
fi
export SERVER_NAME
echo "[entrypoint] SERVER_NAME='$SERVER_NAME' (from APP_URL)"

# 9. Hand off to supervisord
echo "[entrypoint] Starting supervisord ..."
exec /usr/bin/supervisord -c /etc/supervisor/supervisord.conf
