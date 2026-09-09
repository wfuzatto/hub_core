FROM php:8.3-apache-bookworm

ENV APACHE_DOCUMENT_ROOT=/var/www/html

RUN docker-php-ext-install pdo_mysql mysqli \
    && a2enmod rewrite headers

COPY apache-security.conf /etc/apache2/conf-available/hub-security.conf
RUN a2enconf hub-security

COPY public/ /var/www/html/
RUN chown -R www-data:www-data /var/www/html

EXPOSE 80

HEALTHCHECK --interval=15s --timeout=5s --retries=5 --start-period=20s \
  CMD php -r '$c=@file_get_contents("http://127.0.0.1/health.php"); exit($c===false?1:0);'
