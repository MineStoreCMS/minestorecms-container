# MineStoreCMS — Docker / Podman install

This directory provides a containerized install method for MineStoreCMS,
alongside the bare-metal `docs/installer.sh`.

## Quick start

```bash
# Fresh VPS bootstrap (one-liner)
curl -sSL https://minestorecms.com/docker-installer.sh | sudo bash
# Or, if you cloned this repo:
sudo bash docker/installers/docker-installer.sh
```

The installer asks for: instance name, license key, domain, reverse-proxy
choice (Caddy / Nginx / Apache2 / install-Caddy / skip), and DB mode.
It builds the image (license-gated tarball), starts the containers,
generates a reverse-proxy vhost on request, and runs certbot if asked.

## Day-2 ops — `minestore` CLI

```bash
sudo minestore list
sudo minestore status <name>
sudo minestore logs <name> [service]
sudo minestore artisan <name> <cmd>
sudo minestore update <name>          # rebuild image, restart
sudo minestore backup <name>          # tarball of all volumes + db dump
sudo minestore restore <name> --from <file>
sudo minestore destroy <name>         # remove a single instance
sudo minestore uninstall              # remove ALL instances + the CLI itself
sudo minestore proxy create|regenerate|remove|list
```

## Multi-instance

Each instance lives under `/opt/minestore/<name>/`. Compose project name
is `minestore-<name>`, so containers, networks and volumes are
auto-prefixed and never collide.

Example: GreenCraft + RedCraft on the same VPS:

```bash
sudo minestore create greencraft   # picks port 80 if free, else high port
sudo minestore create redcraft     # picks high port (e.g. 18001) + offers
                                   # to install Caddy as shared front-end
```

## Architecture overview

```
                    ┌──────────────────────────────┐
                    │  Caddy / Nginx / Apache2     │  (host)
                    │  TLS + routing by domain     │
                    └──────────┬───────────────────┘
                               │ 127.0.0.1:<port>
            ┌──────────────────┴──────────────────────┐
            │  app container (all-in-one)             │
            │   supervisord → nginx, php-fpm, Next.js │
            │                workers, scheduler,      │
            │                discord, frontend.sh     │
            └──────────────────┬──────────────────────┘
                               │ internal docker network
                    ┌──────────┴───────────┐
                    │  db (mariadb:11)     │
                    └──────────────────────┘
```

State is preserved in named volumes:

| Volume          | Mount point                          |
|-----------------|--------------------------------------|
| env             | /var/lib/minestore-env (symlinked)   |
| storage         | /var/www/minestore/storage           |
| pub-img         | /var/www/minestore/public/img        |
| pub-assets      | /var/www/minestore/public/assets     |
| frontend        | /var/www/minestore/frontend          |
| db-data         | /var/lib/mysql                       |

## Updating

```bash
sudo minestore backup <name>
sudo minestore update <name>
```

`update` runs `compose build --no-cache`, which re-fetches the latest
tarball for your license, then restarts the containers. The entrypoint
runs `artisan migrate --force` and rebuilds the frontend if its
`package.json` hash changed. All volumes (env, storage, public/img,
public/assets, frontend, db-data) persist across the rebuild.

## SSL / TLS

- Caddy options: SSL is automatic (ACME / Let's Encrypt).
- Nginx / Apache options: installer runs `certbot --<webserver> -d <domain>`
  if you choose "certbot" SSL. Renew via cron (host crontab).
- For Cloudflare or external load balancers, choose "Skip" during install
  and configure your own routing to `127.0.0.1:<HTTP_PORT>`.

## Podman notes

- Rootful is recommended (`sudo bash docker-installer.sh`). Rootless works
  but cannot bind privileged ports without:
  ```
  sudo sysctl net.ipv4.ip_unprivileged_port_start=80
  ```
- HEALTHCHECK is preserved because the installer passes `--format=docker`
  to `podman compose build`.
- For boot-time autostart: `sudo minestore install-systemd <name>`
  (generates Podman systemd units in `/etc/systemd/system/`).
- SELinux: named volumes (the default) sidestep label issues. If you
  switch to bind mounts, add `:Z` to each mount.

## Troubleshooting

- **App is unhealthy** — `minestore logs <name>` (default service is `app`).
  Common: DB not reachable (db container unhealthy), bad license key,
  or first-run pnpm install timing out.
- **certbot fails** — DNS not pointing to host yet; port 80 firewalled.
  Re-run: `sudo minestore proxy regenerate <name>`.
- **Update doesn't take effect** — confirm `compose build` actually
  re-fetched the tarball (`--no-cache` was used). Check
  `minestore version <name>`.
- **"Auto-update is disabled in container mode"** — expected. Use
  `sudo minestore update <name>` from the host instead of the admin
  "Upgrade" button.

## Files in this directory

| Path                                       | Purpose |
|--------------------------------------------|---------|
| `Dockerfile`                               | Multi-stage app image |
| `docker-compose.yaml.template`             | Per-instance compose template |
| `.env.example`                             | Host-level env template |
| `conf/`                                    | nginx, supervisord, php, php-fpm, timezone |
| `scripts/docker-entrypoint.sh`             | Container startup orchestration |
| `scripts/healthcheck.sh`                   | HEALTHCHECK target |
| `installers/docker-installer.sh`           | Interactive bootstrap |
| `installers/minestore-cli.sh`              | Host CLI (→ /usr/local/bin/minestore) |
| `installers/lib/ui.sh`                     | Colored UI library |
| `installers/proxy-templates/*.template`    | Reverse-proxy config skeletons |
| `installers/proxy-templates/generate.sh`   | Renders and activates proxy configs |
| `tests/smoke.sh`                           | End-to-end smoke test |
