#!/bin/bash
# minestore — host CLI for managing containerized MineStoreCMS instances.
# Install path: /usr/local/bin/minestore

set -euo pipefail

MINESTORE_ROOT="${MINESTORE_ROOT:-/opt/minestore}"
MINESTORE_VERSION="1.0.0"

# ─── runtime detection ───────────────────────────────────────────────────
# COMPOSE_CMD is an array so multi-word commands (e.g. "docker compose") expand
# safely without falling back to word-splitting of an unquoted variable.
detect_runtime() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        RUNTIME="docker"
        COMPOSE_CMD=(docker compose)
    elif command -v podman >/dev/null 2>&1; then
        RUNTIME="podman"
        if podman compose --version >/dev/null 2>&1; then
            COMPOSE_CMD=(podman compose)
        elif command -v podman-compose >/dev/null 2>&1; then
            COMPOSE_CMD=(podman-compose)
        else
            echo "ERROR: podman found but no compose plugin (\"podman compose\" or \"podman-compose\")." >&2
            exit 2
        fi
    else
        echo "ERROR: neither docker nor podman is installed/usable." >&2
        exit 2
    fi
}

compose() {
    local name="$1"; shift
    local dir="$MINESTORE_ROOT/$name"
    [ -d "$dir" ] || { echo "Instance '$name' not found (no $dir)" >&2; return 1; }
    ( cd "$dir" && "${COMPOSE_CMD[@]}" -p "minestore-$name" "$@" )
}

instance_must_exist() {
    local name="$1"
    [ -d "$MINESTORE_ROOT/$name" ] || { echo "Instance '$name' not found." >&2; exit 1; }
}

list_instances() {
    [ -d "$MINESTORE_ROOT" ] || { echo "(no instances)"; return; }
    printf "%-20s %-12s %-30s %-8s\n" "NAME" "STATUS" "DOMAIN" "PORT"
    for dir in "$MINESTORE_ROOT"/*/; do
        [ -d "$dir" ] || continue
        local name; name=$(basename "$dir")
        [ -f "$dir/instance.conf" ] || continue
        local domain="" port=""
        domain=$(grep -m1 '^APP_DOMAIN=' "$dir/.env" 2>/dev/null | cut -d= -f2-)
        port=$(grep -m1 '^HTTP_PORT=' "$dir/.env" 2>/dev/null | cut -d= -f2-)
        local status="stopped"
        if ( cd "$dir" && "${COMPOSE_CMD[@]}" -p "minestore-$name" ps -q 2>/dev/null | grep -q . ); then
            status="running"
        fi
        printf "%-20s %-12s %-30s %-8s\n" "$name" "$status" "${domain:-?}" "${port:-?}"
    done
}

print_help() {
    cat <<EOF
minestore $MINESTORE_VERSION — manage containerized MineStoreCMS instances

USAGE:
    minestore <command> [args...]

LIFECYCLE
    create [NAME]              Interactive bootstrap (delegates to docker-installer.sh)
    list                       Show all instances
    start <NAME>               Start instance containers
    stop <NAME>                Stop instance containers
    restart <NAME>             Restart instance
    destroy <NAME>             Remove a single instance (containers + volumes + dir)
    uninstall                  Remove ALL instances + the minestore CLI itself

OPERATIONS
    logs <NAME> [SERVICE]      Follow logs (default service: app)
    shell <NAME>               Open bash in the app container
    artisan <NAME> <CMD...>    Run artisan command inside the app container
    status <NAME>              Health + version + queue depth
    tail-laravel <NAME>        Follow storage/logs/laravel.log

UPDATES
    rebuild <NAME>             Rebuild image (refetches license tarball) and restart
    update <NAME>              Alias for rebuild
    version <NAME>             Print installed app version

BACKUPS
    backup <NAME> [--path D]   Tar all volumes to /var/backups/minestore/<name>-DATE.tar.gz
    restore <NAME> --from F    Restore an instance from a backup tarball

PROXY
    proxy create <NAME> --type caddy|nginx|apache2 [--ssl certbot|self|none]
    proxy regenerate <NAME>
    proxy remove <NAME>
    proxy list

MISC
    prune                      Remove dangling images and volumes
    install-systemd <NAME>     Generate Podman systemd unit (boot autostart)
    help                       Show this message

Runtime detected at runtime (Docker or Podman).
EOF
}

# ─── command dispatch ────────────────────────────────────────────────────
detect_runtime
cmd="${1:-help}"; shift || true

case "$cmd" in
    help|--help|-h)  print_help ;;
    list)            list_instances ;;
    start)           instance_must_exist "$1"; compose "$1" up -d ;;
    stop)            instance_must_exist "$1"; compose "$1" stop ;;
    restart)         instance_must_exist "$1"; compose "$1" restart ;;
    logs)
        instance_must_exist "$1"
        svc="${2:-app}"
        compose "$1" logs -f "$svc"
        ;;
    shell)           instance_must_exist "$1"; compose "$1" exec app bash ;;
    artisan)
        instance_must_exist "$1"
        name="$1"; shift
        compose "$name" exec app php /var/www/minestore/artisan "$@"
        ;;
    status)
        instance_must_exist "$1"
        echo "Instance: $1"
        compose "$1" ps
        echo ""
        echo "Health:"
        compose "$1" exec -T app curl -fsS http://127.0.0.1/api/health || echo "  (unhealthy)"
        ;;
    version)
        instance_must_exist "$1"
        compose "$1" exec -T app php /var/www/minestore/artisan tinker --execute='echo config("app.version");'
        ;;
    tail-laravel)
        instance_must_exist "$1"
        compose "$1" exec -T app tail -f /var/www/minestore/storage/logs/laravel.log
        ;;
    create)
        installer="${MINESTORE_INSTALLER:-/usr/local/share/minestore/docker-installer.sh}"
        if [ ! -x "$installer" ]; then
            echo "Installer not found at $installer. Set MINESTORE_INSTALLER or reinstall the CLI." >&2
            exit 2
        fi
        exec "$installer" "$@"
        ;;
    uninstall)
        installer="${MINESTORE_INSTALLER:-/usr/local/share/minestore/docker-installer.sh}"
        if [ ! -x "$installer" ]; then
            echo "Installer not found at $installer. Set MINESTORE_INSTALLER or reinstall the CLI." >&2
            exit 2
        fi
        exec "$installer" --uninstall
        ;;
    proxy)
        sub="${1:-help}"; shift || true
        case "$sub" in
            create)
                name="$1"; shift
                proxy_type=""
                ssl="certbot"
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --type) proxy_type="$2"; shift 2 ;;
                        --ssl)  ssl="$2"; shift 2 ;;
                        *) echo "Unknown arg: $1" >&2; exit 1 ;;
                    esac
                done
                instance_must_exist "$name"
                # shellcheck disable=SC1091
                . "$MINESTORE_ROOT/$name/.env"
                "${MINESTORE_PROXY_GEN:-/usr/local/share/minestore/proxy-templates/generate.sh}" \
                    "$name" "$proxy_type" "$APP_DOMAIN" "$HTTP_PORT" "$ssl"
                ;;
            regenerate)
                name="$1"
                instance_must_exist "$name"
                # shellcheck disable=SC1091
                . "$MINESTORE_ROOT/$name/instance.conf"
                . "$MINESTORE_ROOT/$name/.env"
                "${MINESTORE_PROXY_GEN:-/usr/local/share/minestore/proxy-templates/generate.sh}" \
                    "$name" "$PROXY_TYPE" "$APP_DOMAIN" "$HTTP_PORT" "${SSL_MODE:-certbot}"
                ;;
            remove)
                name="$1"
                rm -f "/etc/caddy/Caddyfile.d/minestore-$name.conf" \
                      "/etc/nginx/sites-enabled/minestore-$name.conf" \
                      "/etc/nginx/sites-available/minestore-$name.conf" \
                      "/etc/apache2/sites-available/minestore-$name.conf" \
                      "/etc/apache2/sites-enabled/minestore-$name.conf"
                systemctl reload caddy 2>/dev/null || true
                systemctl reload nginx 2>/dev/null || true
                systemctl reload apache2 2>/dev/null || true
                echo "Removed proxy configs for $name (where present)."
                ;;
            list)
                ls -1 /etc/caddy/Caddyfile.d/minestore-*.conf 2>/dev/null || true
                ls -1 /etc/nginx/sites-enabled/minestore-*.conf 2>/dev/null || true
                ls -1 /etc/apache2/sites-enabled/minestore-*.conf 2>/dev/null || true
                ;;
            *)
                echo "Usage: minestore proxy {create|regenerate|remove|list} <args>" >&2
                exit 1
                ;;
        esac
        ;;
    rebuild|update)
        name="$1"
        instance_must_exist "$name"
        echo "  * Rebuilding image (re-fetching license tarball) ..."
        compose "$name" build --no-cache
        echo "  * Restarting containers ..."
        compose "$name" up -d
        echo "  * Done. Migrations + frontend rebuild run on entrypoint."
        ;;
    destroy)
        name="$1"
        instance_must_exist "$name"
        read -r -p "This will REMOVE all containers, volumes and files for '$name'. Type the instance name to confirm: " confirm
        if [ "$confirm" != "$name" ]; then
            echo "Aborted." >&2; exit 1
        fi
        compose "$name" down -v --remove-orphans
        rm -rf "${MINESTORE_ROOT:?}/$name"
        echo "Instance '$name' destroyed."
        ;;
    backup)
        name="$1"; shift
        path="/var/backups/minestore"
        while [ $# -gt 0 ]; do
            case "$1" in
                --path) path="$2"; shift 2 ;;
                *) echo "Unknown arg: $1" >&2; exit 1 ;;
            esac
        done
        instance_must_exist "$name"
        mkdir -p "$path"
        ts=$(date -u +%Y%m%dT%H%M%SZ)
        out="$path/$name-$ts.tar.gz"
        echo "Creating backup: $out"
        compose "$name" stop app || true
        sql_tmp=$(mktemp)
        compose "$name" exec -T db sh -c \
          "mariadb-dump --single-transaction --quick --lock-tables=false -u \"\$MARIADB_USER\" -p\"\$MARIADB_PASSWORD\" \"\$MARIADB_DATABASE\"" \
          > "$sql_tmp"
        tmp_dir=$(mktemp -d)
        for vol in env storage pub-img pub-assets frontend; do
            full="minestore-${name}_${vol}"
            "$RUNTIME" run --rm -v "$full":/src -v "$tmp_dir":/dst alpine \
              sh -c "cd /src && tar -czf /dst/$vol.tar.gz ."
        done
        cp "$sql_tmp" "$tmp_dir/db.sql"
        cp "$MINESTORE_ROOT/$name/instance.conf" "$tmp_dir/instance.conf"
        cp "$MINESTORE_ROOT/$name/.env"          "$tmp_dir/host.env"
        tar -C "$tmp_dir" -czf "$out" .
        rm -rf "$tmp_dir" "$sql_tmp"
        compose "$name" start app || compose "$name" up -d
        echo "Backup: $out ($(du -h "$out" | cut -f1))"
        ;;
    restore)
        name="$1"; shift
        file=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --from) file="$2"; shift 2 ;;
                *) echo "Unknown arg: $1" >&2; exit 1 ;;
            esac
        done
        instance_must_exist "$name"
        [ -f "$file" ] || { echo "Backup file not found: $file" >&2; exit 1; }
        read -r -p "Restore will OVERWRITE current state of '$name'. Confirm? (yes/N): " ans
        [ "$ans" = "yes" ] || { echo "Aborted."; exit 1; }
        tmp_dir=$(mktemp -d)
        tar -C "$tmp_dir" -xzf "$file"
        compose "$name" down
        compose "$name" up -d db
        for vol in env storage pub-img pub-assets frontend; do
            full="minestore-${name}_${vol}"
            "$RUNTIME" volume rm "$full" 2>/dev/null || true
            "$RUNTIME" volume create "$full" >/dev/null
            "$RUNTIME" run --rm -v "$full":/dst -v "$tmp_dir":/src alpine \
              sh -c "cd /dst && tar -xzf /src/$vol.tar.gz"
        done
        sleep 5
        compose "$name" exec -T db sh -c \
          "mariadb -u \"\$MARIADB_USER\" -p\"\$MARIADB_PASSWORD\" \"\$MARIADB_DATABASE\"" \
          < "$tmp_dir/db.sql"
        compose "$name" up -d
        rm -rf "$tmp_dir"
        echo "Restored '$name' from $file."
        ;;
    prune)
        "$RUNTIME" image prune -f
        "$RUNTIME" volume prune -f
        ;;
    install-systemd)
        if [ "$RUNTIME" != "podman" ]; then
            echo "install-systemd is only supported on Podman." >&2; exit 2
        fi
        name="$1"
        instance_must_exist "$name"
        cd "$MINESTORE_ROOT/$name"
        podman generate systemd --name --new --files "minestore-$name-app" "minestore-$name-db"
        cp ./*.service /etc/systemd/system/
        systemctl daemon-reload
        for svc in "minestore-$name-app.service" "minestore-$name-db.service"; do
            systemctl enable --now "$svc" || true
        done
        echo "Installed systemd units for $name."
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        print_help
        exit 1
        ;;
esac
