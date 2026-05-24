#!/bin/bash
# Generate / activate a reverse-proxy vhost for an installed instance.
# Usage:
#   generate.sh <INSTANCE> <TYPE: caddy|nginx|apache2|install-caddy> <DOMAIN> <PORT> <SSL: certbot|self|none|caddy-auto>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/ui.sh
. "$SCRIPT_DIR/../lib/ui.sh"

INSTANCE_NAME="$1"
PROXY_TYPE="$2"
APP_DOMAIN="$3"
HTTP_PORT="$4"
SSL_MODE="$5"

render() {
    local tmpl="$1" out="$2"
    INSTANCE_NAME="$INSTANCE_NAME" APP_DOMAIN="$APP_DOMAIN" HTTP_PORT="$HTTP_PORT" \
        envsubst < "$tmpl" > "$out"
}

install_caddy() {
    if ! command -v caddy >/dev/null 2>&1; then
        ui::info "Installing Caddy ..."
        apt-get update -y >/dev/null
        apt-get install -y debian-keyring debian-archive-keyring apt-transport-https >/dev/null
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -y >/dev/null
        apt-get install -y caddy >/dev/null
    fi
    mkdir -p /etc/caddy/Caddyfile.d
    if ! grep -q 'import Caddyfile.d/' /etc/caddy/Caddyfile 2>/dev/null; then
        echo "import Caddyfile.d/*.conf" >> /etc/caddy/Caddyfile
    fi
}

case "$PROXY_TYPE" in
    install-caddy|caddy)
        if [ "$PROXY_TYPE" = "install-caddy" ]; then install_caddy; fi
        mkdir -p /etc/caddy/Caddyfile.d
        out="/etc/caddy/Caddyfile.d/minestore-$INSTANCE_NAME.conf"
        render "$SCRIPT_DIR/caddy.template" "$out"
        ui::ok "Wrote $out"
        caddy validate --config /etc/caddy/Caddyfile || { ui::fail "Caddy validate failed"; exit 1; }
        systemctl reload caddy
        ;;
    nginx)
        out="/etc/nginx/sites-available/minestore-$INSTANCE_NAME.conf"
        render "$SCRIPT_DIR/nginx.template" "$out"
        ln -sf "$out" "/etc/nginx/sites-enabled/minestore-$INSTANCE_NAME.conf"
        nginx -t || { ui::fail "nginx -t failed"; exit 1; }
        systemctl reload nginx
        ui::ok "Wrote $out and enabled it"
        if [ "$SSL_MODE" = "certbot" ]; then
            ui::info "Running certbot --nginx -d $APP_DOMAIN ..."
            certbot --nginx -d "$APP_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect \
                || ui::warn "certbot failed; check DNS, port 80, and run manually."
        fi
        ;;
    apache2)
        out="/etc/apache2/sites-available/minestore-$INSTANCE_NAME.conf"
        render "$SCRIPT_DIR/apache2.template" "$out"
        a2enmod proxy proxy_http rewrite ssl headers >/dev/null
        a2ensite "minestore-$INSTANCE_NAME" >/dev/null
        apachectl configtest || { ui::fail "Apache configtest failed"; exit 1; }
        systemctl reload apache2
        ui::ok "Wrote $out and enabled it"
        if [ "$SSL_MODE" = "certbot" ]; then
            certbot --apache -d "$APP_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect \
                || ui::warn "certbot failed"
        fi
        ;;
    skip)
        ui::warn "Skipping reverse-proxy configuration as requested."
        ;;
    *)
        ui::fail "Unknown proxy type: $PROXY_TYPE"
        exit 2
        ;;
esac
