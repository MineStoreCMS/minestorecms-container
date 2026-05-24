#!/bin/bash
# docker-installer.sh — interactive bootstrap for a containerized MineStoreCMS.
#
# Usage:
#   sudo bash docker-installer.sh              Interactive install
#   sudo bash docker-installer.sh --uninstall  Remove ALL instances + the CLI
#
# Optional env:
#   MINESTORE_ROOT=/opt/minestore   (where instances live)
#   MINESTORE_REPO=/srv/minestore-src (path to repo with the Dockerfile)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
. "$SCRIPT_DIR/lib/ui.sh"

MINESTORE_ROOT="${MINESTORE_ROOT:-/opt/minestore}"
MINESTORE_REPO="${MINESTORE_REPO:-$SCRIPT_DIR/../..}"

# ─── CLI arg parsing ─────────────────────────────────────────────────────
MODE="install"
while [ $# -gt 0 ]; do
    case "$1" in
        --uninstall) MODE="uninstall"; shift ;;
        --help|-h)
            cat <<USAGE
docker-installer.sh — MineStoreCMS Docker installer

Usage:
    sudo bash docker-installer.sh              Interactive install
    sudo bash docker-installer.sh --uninstall  Remove ALL instances + CLI
    sudo bash docker-installer.sh --help       Show this message

Optional env:
    MINESTORE_ROOT=/opt/minestore       Instance root (default)
    MINESTORE_REPO=/srv/minestore-src   Repo path for builds (default)
USAGE
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

require_root() {
    if [ "$EUID" -ne 0 ]; then
        ui::fail "Please run as root (sudo)."
        exit 1
    fi
}

detect_environment() {
    OS=""; OS_VER=""; RUNTIME=""; COMPOSE_CMD=()
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS="${ID:-unknown}"
        OS_VER="${VERSION_ID:-?}"
    fi

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        RUNTIME="Docker $(docker --version | awk '{print $3}' | tr -d ,)"
        COMPOSE_CMD=(docker compose)
    elif command -v podman >/dev/null 2>&1; then
        RUNTIME="Podman $(podman --version | awk '{print $3}')"
        if podman compose --version >/dev/null 2>&1; then
            COMPOSE_CMD=(podman compose)
        else
            COMPOSE_CMD=(podman-compose)
        fi
    fi

    DETECTED_WEBSERVERS=()
    for ws in nginx caddy apache2; do
        if systemctl is-active --quiet "$ws" 2>/dev/null; then
            DETECTED_WEBSERVERS+=("$ws (active)")
        elif command -v "$ws" >/dev/null 2>&1 || command -v "${ws}ctl" >/dev/null 2>&1; then
            DETECTED_WEBSERVERS+=("$ws (installed, not active)")
        fi
    done
}

print_environment() {
    ui::info "Detected environment:"
    ui::bullet "OS:        $OS $OS_VER"
    if [ -n "$RUNTIME" ]; then
        ui::bullet "Runtime:   ${C_SUCCESS}${UI_OK}${C_NC} $RUNTIME"
        ui::bullet "Compose:   ${C_SUCCESS}${UI_OK}${C_NC} ${COMPOSE_CMD[*]}"
    else
        ui::fail "No container runtime found. Install docker or podman first."
        exit 2
    fi
    if [ ${#DETECTED_WEBSERVERS[@]} -gt 0 ]; then
        ui::bullet "Webservers detected:"
        for w in "${DETECTED_WEBSERVERS[@]}"; do
            ui::bullet "  - $w"
        done
    else
        ui::bullet "Webservers: none active"
    fi
    ui::nl
}

check_domain_unique() {
    local dom="$1"
    if [ -d "$MINESTORE_ROOT" ]; then
        for f in "$MINESTORE_ROOT"/*/.env; do
            [ -f "$f" ] || continue
            if grep -q "^APP_DOMAIN=$dom$" "$f"; then
                local existing
                existing=$(basename "$(dirname "$f")")
                ui::fail "Domain $dom is already used by instance '$existing'."
                exit 1
            fi
        done
    fi
}

prompt_instance_name() {
    ui::step 1 6 "Instance name"
    echo "       Lowercase alphanumeric. Used for the folder and Docker project name."
    ui::nl
    while :; do
        INSTANCE_NAME=$(ui::input "Instance name" "minestore")
        if [[ "$INSTANCE_NAME" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
            if [ -d "$MINESTORE_ROOT/$INSTANCE_NAME" ]; then
                ui::warn "Instance '$INSTANCE_NAME' already exists in $MINESTORE_ROOT."
            else
                break
            fi
        else
            ui::warn "Use lowercase alphanumeric + - _ only."
        fi
    done
}

prompt_license() {
    ui::step 2 6 "License key"
    echo "       Get yours at https://minestorecms.com/dashboard"
    ui::nl
    while :; do
        LICENSE_KEY=$(ui::input "License key")
        ui::spinner_start "Verifying license"
        local resp
        resp=$(curl -fsS "https://minestorecms.com/api/verify/$LICENSE_KEY" 2>/dev/null || true)
        if echo "$resp" | grep -q SUCCESS; then
            ui::spinner_stop ok
            break
        else
            ui::spinner_stop fail
            ui::warn "License rejected by minestorecms.com. Try again."
        fi
    done
}

prompt_domain() {
    ui::step 3 6 "Domain"
    ui::nl
    APP_DOMAIN=$(ui::input "Public domain (e.g. shop.example.com)")
    APP_URL="https://$APP_DOMAIN"
    check_domain_unique "$APP_DOMAIN"
}

prompt_proxy() {
    ui::step 4 6 "Reverse proxy & SSL"
    ui::nl

    local default_choice=2
    local opts=()
    opts+=("Generate Nginx vhost")
    opts+=("Generate Caddy config")
    opts+=("Generate Apache2 vhost")
    opts+=("Install Caddy now")
    opts+=("Skip — I'll handle it myself")

    for w in "${DETECTED_WEBSERVERS[@]:-}"; do
        case "$w" in
            "nginx (active)")   default_choice=1; opts[0]="Generate Nginx vhost (Recommended — Nginx detected on host)" ;;
            "caddy (active)")   default_choice=2; opts[1]="Generate Caddy config (Recommended — Caddy detected on host)" ;;
            "apache2 (active)") default_choice=3; opts[2]="Generate Apache2 vhost (Recommended — Apache detected on host)" ;;
        esac
    done
    if [ ${#DETECTED_WEBSERVERS[@]} -eq 0 ]; then
        default_choice=4
        opts[3]="Install Caddy now (Recommended — no webserver detected)"
    fi

    PROXY_CHOICE=$(ui::select "How do you want to expose this instance?" "$default_choice" "${opts[@]}")
    case "$PROXY_CHOICE" in
        1) PROXY_TYPE="nginx" ;;
        2) PROXY_TYPE="caddy" ;;
        3) PROXY_TYPE="apache2" ;;
        4) PROXY_TYPE="install-caddy" ;;
        5) PROXY_TYPE="skip" ;;
        *) PROXY_TYPE="skip" ;;
    esac
    ui::nl

    if [ "$PROXY_TYPE" != "skip" ]; then
        if [ "$PROXY_TYPE" = "caddy" ] || [ "$PROXY_TYPE" = "install-caddy" ]; then
            SSL_MODE="caddy-auto"
        else
            local ssl_choice
            ssl_choice=$(ui::select "SSL certificate?" "1" \
                "Run certbot now for Let's Encrypt (Recommended)" \
                "I have my own cert (will prompt for paths)" \
                "HTTP only — no SSL")
            case "$ssl_choice" in
                1) SSL_MODE="certbot" ;;
                2) SSL_MODE="self" ;;
                3) SSL_MODE="none" ;;
                *) SSL_MODE="certbot" ;;
            esac
        fi
    fi
}

prompt_database() {
    ui::step 5 6 "Database"
    ui::nl
    local db_choice
    db_choice=$(ui::select "Database source?" "1" \
        "Bundled MariaDB (Recommended — isolated container per instance)" \
        "External MySQL/MariaDB (I have a DB host elsewhere)")
    case "$db_choice" in
        1) DB_MODE="bundled" ;;
        2) DB_MODE="external" ;;
        *) DB_MODE="bundled" ;;
    esac

    if [ "$DB_MODE" = "external" ]; then
        EXT_DB_HOST=$(ui::input "DB host")
        EXT_DB_PORT=$(ui::input "DB port" "3306")
        EXT_DB_NAME=$(ui::input "DB name" "minestore")
        EXT_DB_USER=$(ui::input "DB user" "minestore")
        EXT_DB_PASS=$(ui::input "DB password")
    fi
}

pick_port() {
    if [[ "${COMPOSE_CMD[0]}" =~ podman ]] && [ "$EUID" -ne 0 ]; then
        ui::warn "Rootless Podman cannot bind ports < 1024 without:"
        ui::bullet "sudo sysctl net.ipv4.ip_unprivileged_port_start=80"
        ui::bullet "OR use sudo for this install (rootful Podman)."
    fi
    HTTP_PORT="${HTTP_PORT_OVERRIDE:-80}"
    if [ "$PROXY_TYPE" != "skip" ] && [ "$PROXY_TYPE" != "install-caddy" ]; then
        HTTP_PORT=18000
        while ss -tln "( sport = :$HTTP_PORT )" 2>/dev/null | grep -q LISTEN \
              || (command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$HTTP_PORT" -sTCP:LISTEN >/dev/null 2>&1); do
            HTTP_PORT=$((HTTP_PORT + 1))
        done
    else
        if ss -tln "( sport = :80 )" 2>/dev/null | grep -q LISTEN; then
            ui::warn "Port 80 is busy."
            HTTP_PORT=$(ui::input "Pick another host port" "8080")
        fi
    fi
}

confirm_and_build() {
    ui::step 6 6 "Confirm"
    ui::nl
    echo "       ${C_BOLD}Instance:${C_NC}        $INSTANCE_NAME"
    echo "       ${C_BOLD}Domain:${C_NC}          $APP_DOMAIN"
    echo "       ${C_BOLD}License:${C_NC}         ${LICENSE_KEY:0:8}…  ${C_SUCCESS}${UI_OK}${C_NC} verified"
    echo "       ${C_BOLD}DB:${C_NC}              $DB_MODE"
    echo "       ${C_BOLD}Reverse proxy:${C_NC}   $PROXY_TYPE  (SSL: ${SSL_MODE:-n/a})"
    echo "       ${C_BOLD}HTTP port:${C_NC}       $HTTP_PORT"
    echo "       ${C_BOLD}Install path:${C_NC}    $MINESTORE_ROOT/$INSTANCE_NAME"
    ui::nl
    if ! ui::confirm "Proceed?"; then
        ui::warn "Aborted."
        exit 1
    fi
    ui::nl
}

render_files() {
    local dir="$MINESTORE_ROOT/$INSTANCE_NAME"
    mkdir -p "$dir"

    local db_pass
    db_pass=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
    cat > "$dir/.env" <<EOF
INSTANCE_NAME=$INSTANCE_NAME
LICENSE_KEY=$LICENSE_KEY
APP_DOMAIN=$APP_DOMAIN
APP_URL=$APP_URL
APP_ENV=production
APP_DEBUG=false
TIMEZONE=${TIMEZONE:-UTC}
LOCALE=en
DB_DATABASE=${EXT_DB_NAME:-minestore}
DB_USERNAME=${EXT_DB_USER:-minestore}
DB_PASSWORD=${EXT_DB_PASS:-$db_pass}
HTTP_PORT=$HTTP_PORT
REPO_PATH=$MINESTORE_REPO
EOF

    INSTANCE_NAME="$INSTANCE_NAME" \
    LICENSE_KEY="$LICENSE_KEY" \
    APP_URL="$APP_URL" \
    HTTP_PORT="$HTTP_PORT" \
    DB_PASSWORD="${EXT_DB_PASS:-$db_pass}" \
    DB_USERNAME="${EXT_DB_USER:-minestore}" \
    DB_DATABASE="${EXT_DB_NAME:-minestore}" \
    REPO_PATH="$MINESTORE_REPO" \
        envsubst < "$SCRIPT_DIR/../docker-compose.yaml.template" > "$dir/docker-compose.yaml"

    cat > "$dir/instance.conf" <<EOF
INSTANCE_NAME=$INSTANCE_NAME
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUNTIME=$RUNTIME
DOMAIN=$APP_DOMAIN
HTTP_PORT=$HTTP_PORT
DB_MODE=$DB_MODE
PROXY_TYPE=$PROXY_TYPE
SSL_MODE=${SSL_MODE:-}
EOF
    chmod 600 "$dir/.env"
}

build_and_start() {
    local dir="$MINESTORE_ROOT/$INSTANCE_NAME"
    ui::info "Building image (this takes 3-5 minutes on first run)..."
    # Podman defaults to OCI image format, which strips HEALTHCHECK metadata.
    # Pass --format=docker so the HEALTHCHECK survives into the image.
    if [[ "${COMPOSE_CMD[0]}" =~ podman ]]; then
        ( cd "$dir" && "${COMPOSE_CMD[@]}" -p "minestore-$INSTANCE_NAME" build --format docker ) \
            || { ui::fail "Build failed."; exit 4; }
    else
        ( cd "$dir" && "${COMPOSE_CMD[@]}" -p "minestore-$INSTANCE_NAME" build ) \
            || { ui::fail "Build failed."; exit 4; }
    fi
    ui::ok "Image built."

    ui::info "Starting containers ..."
    ( cd "$dir" && "${COMPOSE_CMD[@]}" -p "minestore-$INSTANCE_NAME" up -d ) \
        || { ui::fail "Failed to start."; exit 5; }
    ui::ok "Containers started."

    ui::info "Waiting for healthy state ..."
    local tries=60
    while [ $tries -gt 0 ]; do
        if ( cd "$dir" && "${COMPOSE_CMD[@]}" -p "minestore-$INSTANCE_NAME" ps app \
             | grep -q "healthy" ); then
            ui::ok "App is healthy."
            return 0
        fi
        sleep 5
        tries=$((tries - 1))
    done
    ui::warn "App did not reach healthy state in 5 minutes. Inspect logs with:"
    ui::bullet "minestore logs $INSTANCE_NAME"
}

print_summary() {
    ui::nl
    ui::line
    ui::ok "${C_BOLD}$INSTANCE_NAME is ready!${C_NC}"
    ui::nl
    ui::bullet "Public URL:   $APP_URL"
    ui::bullet "Admin login:  $APP_URL/admin"
    ui::nl
    ui::info "Useful commands:"
    ui::bullet "minestore status $INSTANCE_NAME"
    ui::bullet "minestore logs $INSTANCE_NAME"
    ui::bullet "minestore artisan $INSTANCE_NAME ..."
    ui::bullet "minestore update $INSTANCE_NAME"
    ui::bullet "minestore help"
    ui::nl
    ui::line
}

# ─── uninstall ───────────────────────────────────────────────────────────
uninstall_all() {
    ui::section "Full uninstall — removes ALL MineStoreCMS Docker instances"

    # Gather instances
    local instances=()
    if [ -d "$MINESTORE_ROOT" ]; then
        for dir in "$MINESTORE_ROOT"/*/; do
            [ -d "$dir" ] || continue
            [ -f "$dir/instance.conf" ] || continue
            instances+=("$(basename "$dir")")
        done
    fi

    if [ ${#instances[@]} -eq 0 ]; then
        ui::info "No instances registered under $MINESTORE_ROOT."
    else
        ui::info "Found ${#instances[@]} instance(s):"
        for n in "${instances[@]}"; do
            local domain="" port=""
            domain=$(grep -m1 '^APP_DOMAIN=' "$MINESTORE_ROOT/$n/.env" 2>/dev/null | cut -d= -f2-)
            port=$(grep -m1 '^HTTP_PORT='   "$MINESTORE_ROOT/$n/.env" 2>/dev/null | cut -d= -f2-)
            ui::bullet "$n  →  ${domain:-?} (host port ${port:-?})"
        done
        ui::nl
    fi

    ui::warn "This will:"
    ui::bullet "Stop and DELETE all containers, volumes and networks for every instance"
    ui::bullet "Remove all proxy configs (Caddy/Nginx/Apache2) for these instances"
    ui::bullet "Remove the \`minestore\` CLI from /usr/local/bin/"
    ui::bullet "Remove /usr/local/share/minestore/"
    ui::bullet "Optionally remove $MINESTORE_ROOT (if empty after cleanup)"
    ui::nl
    ui::warn "${C_BOLD}This is irreversible. Backups are NOT taken automatically.${C_NC}"
    ui::nl

    local confirm=""
    read -r -p "     Type ${C_ERROR}UNINSTALL${C_NC} to confirm: " confirm
    if [ "$confirm" != "UNINSTALL" ]; then
        ui::warn "Aborted — no changes made."
        exit 0
    fi
    ui::nl

    # Per-instance teardown
    for n in "${instances[@]}"; do
        local dir="$MINESTORE_ROOT/$n"
        ui::info "Removing instance: $n"
        if [ ${#COMPOSE_CMD[@]} -gt 0 ] && [ -f "$dir/docker-compose.yaml" ]; then
            ( cd "$dir" && "${COMPOSE_CMD[@]}" -p "minestore-$n" down -v --remove-orphans ) 2>/dev/null \
                || ui::warn "  compose down failed for $n (containers may already be removed)"
        fi
        # Proxy configs
        rm -f "/etc/caddy/Caddyfile.d/minestore-$n.conf" \
              "/etc/nginx/sites-enabled/minestore-$n.conf" \
              "/etc/nginx/sites-available/minestore-$n.conf" \
              "/etc/apache2/sites-enabled/minestore-$n.conf" \
              "/etc/apache2/sites-available/minestore-$n.conf" 2>/dev/null || true
        rm -rf "$dir"
        ui::ok "$n removed"
    done

    # Reload webservers (best-effort) so freed configs leave gracefully
    for svc in caddy nginx apache2; do
        systemctl reload "$svc" 2>/dev/null || true
    done

    # Remove CLI + shared dir
    if [ -f /usr/local/bin/minestore ]; then
        rm -f /usr/local/bin/minestore
        ui::ok "Removed /usr/local/bin/minestore"
    fi
    if [ -d /usr/local/share/minestore ]; then
        rm -rf /usr/local/share/minestore
        ui::ok "Removed /usr/local/share/minestore"
    fi

    # Offer to remove the (now-empty) parent dir
    if [ -d "$MINESTORE_ROOT" ] && [ -z "$(ls -A "$MINESTORE_ROOT" 2>/dev/null)" ]; then
        if ui::confirm "Remove empty $MINESTORE_ROOT directory?"; then
            rmdir "$MINESTORE_ROOT" 2>/dev/null && ui::ok "Removed $MINESTORE_ROOT"
        fi
    fi

    ui::nl
    ui::line
    ui::ok "${C_BOLD}MineStoreCMS Docker fully uninstalled.${C_NC}"
    ui::nl
    ui::info "Docker images themselves are NOT removed. To reclaim that space:"
    ui::bullet "${COMPOSE_CMD[0]:-docker} image prune -a"
    ui::bullet "${COMPOSE_CMD[0]:-docker} system prune -a --volumes   (heavy — removes ALL unused docker state)"
    ui::line
}

# ─── main ────────────────────────────────────────────────────────────────
ui::trap_ctrl_c
require_root
ui::banner
detect_environment
print_environment

if [ "$MODE" = "uninstall" ]; then
    uninstall_all
    exit 0
fi

prompt_instance_name
prompt_license
prompt_domain
prompt_proxy
prompt_database
pick_port
confirm_and_build
render_files
build_and_start
# proxy config + SSL handled in Phase 6 hook
if [ "${PROXY_TYPE:-skip}" != "skip" ] && \
   [ -x "$SCRIPT_DIR/proxy-templates/generate.sh" ]; then
    "$SCRIPT_DIR/proxy-templates/generate.sh" \
        "$INSTANCE_NAME" "$PROXY_TYPE" "$APP_DOMAIN" "$HTTP_PORT" "${SSL_MODE:-none}"
fi
print_summary
