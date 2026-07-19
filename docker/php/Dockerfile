FROM php:8.2-fpm

WORKDIR /var/www/csat

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

RUN pecl install xdebug \
    && docker-php-ext-enable xdebug

COPY docker/php/php.ini /usr/local/etc/php/conf.d/
COPY docker/php/xdebug.ini /usr/local/etc/php/conf.d/

COPY --from=composer:2.7 /usr/bin/composer /usr/bin/composer

COPY api-service/composer.json api-service/composer.lock /var/www/csat/

RUN composer install --no-interaction --prefer-dist --no-scripts --no-progress

COPY . .

RUN chown -R www-data:www-data /var/www/csat

EXPOSE 9000

CMD ["php-fpm"]
