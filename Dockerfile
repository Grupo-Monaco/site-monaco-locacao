# ============================================================
# Stage 1: Dependências PHP (Composer)
# ============================================================
FROM composer:2.8 AS composer-deps

WORKDIR /app

COPY composer.json composer.lock ./
COPY database/ database/

RUN composer install \
    --no-dev \
    --optimize-autoloader \
    --no-scripts \
    --no-interaction \
    --prefer-dist \
    --ignore-platform-req=ext-oci8

COPY . .

RUN mkdir -p bootstrap/cache \
    && composer dump-autoload --optimize --no-dev

# ============================================================
# Stage 2: Build dos assets Node/Vite
# ============================================================
FROM node:18-alpine AS node-builder

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --prefer-offline

COPY . .

# Vite resolve ziggy-js via vendor/tightenco/ziggy
COPY --from=composer-deps /app/vendor ./vendor

RUN npm run build

# ============================================================
# Stage 3: Imagem de produção (PHP-FPM + Nginx + Supervisord)
# ============================================================
FROM php:8.3-fpm-bookworm AS runtime

# Dependências do sistema + extensões PHP + OPcache
RUN apt-get update && apt-get install -y \
    nginx \
    supervisor \
    unzip \
    curl \
    libaio1 \
    libonig-dev \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libpq-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) gd pdo pdo_mysql pdo_pgsql opcache \
    && echo "opcache.enable=1" >> /usr/local/etc/php/conf.d/opcache.ini \
    && echo "opcache.memory_consumption=256" >> /usr/local/etc/php/conf.d/opcache.ini \
    && echo "opcache.max_accelerated_files=20000" >> /usr/local/etc/php/conf.d/opcache.ini \
    && echo "opcache.validate_timestamps=0" >> /usr/local/etc/php/conf.d/opcache.ini

# Oracle Instant Client
ENV ORACLE_BASE=/opt/oracle
ENV ORACLE_HOME=/opt/oracle/instantclient
ENV LD_LIBRARY_PATH=/opt/oracle/instantclient
ENV TNS_ADMIN=/opt/oracle/instantclient/network/admin
ENV PATH=$ORACLE_HOME:$PATH

RUN mkdir -p /opt/oracle \
    && curl -o /opt/oracle/instantclient-basic.zip \
       https://download.oracle.com/otn_software/linux/instantclient/2112000/instantclient-basic-linux.x64-21.12.0.0.0dbru.zip \
    && curl -o /opt/oracle/instantclient-sdk.zip \
       https://download.oracle.com/otn_software/linux/instantclient/2112000/instantclient-sdk-linux.x64-21.12.0.0.0dbru.zip \
    && unzip -o /opt/oracle/instantclient-basic.zip -d /opt/oracle \
    && unzip -o /opt/oracle/instantclient-sdk.zip -d /opt/oracle \
    && rm /opt/oracle/instantclient-basic.zip /opt/oracle/instantclient-sdk.zip \
    && ln -s /opt/oracle/instantclient_21_12 /opt/oracle/instantclient \
    && ln -s /opt/oracle/instantclient/sdk/include /usr/include/oracle \
    && echo /opt/oracle/instantclient > /etc/ld.so.conf.d/oracle-instantclient.conf \
    && ldconfig \
    && docker-php-ext-configure oci8 --with-oci8=instantclient,/opt/oracle/instantclient \
    && docker-php-ext-install oci8 \
    && docker-php-ext-configure pdo_oci --with-pdo-oci=instantclient,/opt/oracle/instantclient \
    && docker-php-ext-install pdo_oci

WORKDIR /var/www/html

# Copia a aplicação
COPY --chown=www-data:www-data . .

# Copia vendor e build gerados nos stages anteriores
COPY --from=composer-deps --chown=www-data:www-data /app/vendor ./vendor
COPY --from=node-builder  --chown=www-data:www-data /app/public/build ./public/build

# Configurações do servidor
COPY docker/nginx.conf       /etc/nginx/sites-available/default
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/entrypoint.sh    /entrypoint.sh

RUN chmod +x /entrypoint.sh \
    && chmod -R 775 /var/www/html/storage /var/www/html/bootstrap/cache \
    && chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache \
    && rm -f /etc/nginx/sites-enabled/default \
    && ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
