#!/bin/bash
# bootstrap.sh — fetches the container repo (or skip if present) and runs docker-installer.sh.
# Intended for: curl -sSL https://minestorecms.com/docker-installer.sh | sudo bash
# (You serve this file at that URL.)

set -euo pipefail

REPO_URL="${MINESTORE_REPO_URL:-https://github.com/MineStoreCMS/minestorecms-container.git}"
REPO_DIR="${MINESTORE_REPO_DIR:-/srv/minestorecms-src}"

if ! command -v git >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y --no-install-recommends git
fi

if [ ! -d "$REPO_DIR/.git" ]; then
    git clone --depth=1 "$REPO_URL" "$REPO_DIR"
else
    (cd "$REPO_DIR" && git fetch --depth=1 origin && git reset --hard origin/HEAD)
fi

if [ ! -f "$REPO_DIR/installers/docker-installer.sh" ]; then
    echo "ERROR: $REPO_DIR/installers/docker-installer.sh is missing." >&2
    echo "       The container repo layout is unexpected. Open an issue:" >&2
    echo "       https://github.com/MineStoreCMS/minestorecms-container/issues" >&2
    exit 1
fi

# Install the CLI globally so users can run `minestore` from anywhere
install -m 0755 "$REPO_DIR/installers/minestore-cli.sh" /usr/local/bin/minestore
mkdir -p /usr/local/share/minestore
cp -a "$REPO_DIR/installers/proxy-templates" /usr/local/share/minestore/
install -m 0755 "$REPO_DIR/installers/docker-installer.sh" /usr/local/share/minestore/docker-installer.sh
cp -a "$REPO_DIR/installers/lib" /usr/local/share/minestore/

# Run the interactive installer
MINESTORE_REPO="$REPO_DIR" exec bash "$REPO_DIR/installers/docker-installer.sh"
