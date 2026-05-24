# syntax=docker/dockerfile:1.6

# ─── Stage 1: fetch the license-gated tarball ────────────────────────────
FROM debian:bookworm-slim AS source
ARG LICENSE_KEY
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget ca-certificates tar gzip \
    && rm -rf /var/lib/apt/lists/*
RUN test -n "$LICENSE_KEY" || (echo "LICENSE_KEY build-arg is required" && exit 1)
RUN mkdir /app && \
    wget "https://minestorecms.com/download/v3/${LICENSE_KEY}" \
         -O /tmp/app.tar.gz && \
    tar -xzf /tmp/app.tar.gz -C /app && \
    rm /tmp/app.tar.gz

# ─── Stage 2: runtime ────────────────────────────────────────────────────
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive \
    PNPM_HOME=/usr/local/share/pnpm \
    PATH=/usr/local/share/pnpm:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    COMPOSER_ALLOW_SUPERUSER=1

# Base packages
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release apt-transport-https \
        supervisor nginx tini netcat-traditional sudo locales \
        unzip git \
    && rm -rf /var/lib/apt/lists/*

# PHP 8.3 (sury repository)
RUN curl -sSL https://packages.sury.org/php/apt.gpg \
        | gpg --dearmor -o /usr/share/keyrings/sury.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/sury.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/php.list && \
    apt-get update && apt-get install -y --no-install-recommends \
        php8.3 php8.3-fpm php8.3-cli php8.3-common php8.3-curl php8.3-mbstring \
        php8.3-xml php8.3-zip php8.3-gd php8.3-mysql php8.3-soap php8.3-xmlrpc \
        php8.3-mysqli php8.3-bcmath php8.3-intl \
    && rm -rf /var/lib/apt/lists/*

# Composer
RUN curl -sS https://getcomposer.org/installer | php8.3 -- \
        --install-dir=/usr/local/bin --filename=composer

# Node 22 + pnpm + pm2
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g pnpm pm2@latest && \
    rm -rf /var/lib/apt/lists/*

# Custom timezone extension
COPY conf/timezone.so /usr/lib/php/20230831/timezone.so
COPY conf/timezone.ini /etc/php/8.3/fpm/conf.d/30-timezone.ini
COPY conf/timezone.ini /etc/php/8.3/cli/conf.d/30-timezone.ini

# PHP overrides + FPM pool
COPY conf/php-ini-overrides.ini /etc/php/8.3/fpm/conf.d/99-minestore.ini
COPY conf/php-ini-overrides.ini /etc/php/8.3/cli/conf.d/99-minestore.ini
COPY conf/php-fpm-www.conf /etc/php/8.3/fpm/pool.d/www.conf
RUN mkdir -p /run/php && chown www-data:www-data /run/php

# Nginx
COPY conf/nginx-minestore.conf /etc/nginx/sites-available/minestore.conf
RUN rm -f /etc/nginx/sites-enabled/default && \
    ln -s /etc/nginx/sites-available/minestore.conf \
          /etc/nginx/sites-enabled/minestore.conf

# Supervisord
COPY conf/supervisord.conf /etc/supervisor/supervisord.conf
COPY conf/supervisor-programs.conf /etc/supervisor/conf.d/minestore.conf

# Locale
RUN sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen && \
    update-locale LANG=en_US.UTF-8

# App code — copy the licensed tarball into defaults AND working dir
COPY --from=source /app /opt/minestore-defaults
RUN cp -a /opt/minestore-defaults /var/www/minestore && \
    chown -R www-data:www-data /var/www/minestore

# Composer install
WORKDIR /var/www/minestore
RUN composer install --no-dev --no-progress --optimize-autoloader --no-interaction

# Frontend deps
WORKDIR /var/www/minestore/frontend
RUN pnpm install --prefer-offline --no-frozen-lockfile || pnpm install
WORKDIR /var/www/minestore

# Entrypoint + healthcheck
COPY scripts/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/healthcheck.sh

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=5 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/docker-entrypoint.sh"]
