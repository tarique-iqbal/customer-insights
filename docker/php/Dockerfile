FROM php:8.2-fpm AS base

WORKDIR /var/www/api

RUN apt-get update && apt-get install -y \
        git \
        unzip \
        libpq-dev \
        libzip-dev \
        zip \
        libonig-dev \
        curl \
    && docker-php-ext-install \
        pdo \
        pdo_mysql \
        zip \
        mbstring \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY docker/php/php.ini /usr/local/etc/php/conf.d/

COPY --from=composer:2.7 /usr/bin/composer /usr/bin/composer

COPY api-service/composer.json api-service/composer.lock /var/www/api/

# prod: no xdebug, no dev dependencies. Built with --target prod (CI only).
FROM base AS prod

RUN composer install --no-interaction --prefer-dist --no-scripts --no-progress --no-dev --optimize-autoloader

COPY api-service/. .

RUN mkdir -p var/log \
    && chown -R www-data:www-data /var/www/api

EXPOSE 9000

CMD ["php-fpm"]

# dev: xdebug + all dependencies. Last stage, so a plain build defaults here.
FROM base AS dev

RUN pecl install xdebug \
    && docker-php-ext-enable xdebug

COPY docker/php/xdebug.ini /usr/local/etc/php/conf.d/

RUN composer install --no-interaction --prefer-dist --no-scripts --no-progress

COPY api-service/. .

RUN mkdir -p var/log \
    && chown -R www-data:www-data /var/www/api

EXPOSE 9000

CMD ["php-fpm"]
