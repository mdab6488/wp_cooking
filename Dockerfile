FROM wordpress:latest

# Environment variables for configuration
ENV REDIS_HOST=redis \
    REDIS_PORT=6379 \
    REDIS_PASSWORD=""

# Install system dependencies
RUN apt-get update && apt-get install -y \
    libmagickwand-dev \
    libwebp-dev \
    libjpeg-dev \
    libpng-dev \
    libzip-dev \
    pkg-config \
    redis-tools \
    curl \
    less \
    mariadb-client \
    cron \
    --no-install-recommends

# Install PHP extensions
RUN pecl install imagick redis && \
    docker-php-ext-enable imagick redis && \
    docker-php-ext-configure gd --with-webp --with-jpeg && \
    docker-php-ext-install gd zip mysqli pdo_mysql opcache

# Clean up
RUN apt-get clean && rm -rf /var/lib/apt/lists/*

# Install WP-CLI (latest stable version)
RUN curl -fsSL -o /tmp/wp-cli.phar "https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar" && \
    chmod +x /tmp/wp-cli.phar && \
    mv /tmp/wp-cli.phar /usr/local/bin/wp && \
    wp --info --allow-root

# Create necessary directories and set permissions
RUN mkdir -p /var/www/.opcache && \
    mkdir -p /var/www/html/wp-content/cache && \
    mkdir -p /var/www/html/wp-content/uploads && \
    mkdir -p /var/www/html/wp-content/plugins && \
    mkdir -p /var/www/html/wp-content/themes && \
    mkdir -p /var/log/php && \
    chown -R www-data:www-data /var/www/.opcache /var/www/html/wp-content /var/log/php

# Apache optimization and security
RUN a2enmod expires headers rewrite deflate ssl http2 && \
    a2dismod status && \
    { \
    echo '<IfModule mod_expires.c>'; \
    echo '  ExpiresActive On'; \
    echo '  ExpiresByType image/jpg "access plus 1 year"'; \
    echo '  ExpiresByType image/jpeg "access plus 1 year"'; \
    echo '  ExpiresByType image/gif "access plus 1 year"'; \
    echo '  ExpiresByType image/png "access plus 1 year"'; \
    echo '  ExpiresByType image/webp "access plus 1 year"'; \
    echo '  ExpiresByType image/svg+xml "access plus 1 year"'; \
    echo '  ExpiresByType text/css "access plus 1 month"'; \
    echo '  ExpiresByType application/pdf "access plus 1 month"'; \
    echo '  ExpiresByType text/javascript "access plus 1 month"'; \
    echo '  ExpiresByType application/javascript "access plus 1 month"'; \
    echo '  ExpiresByType application/x-javascript "access plus 1 month"'; \
    echo '  ExpiresByType font/woff "access plus 1 year"'; \
    echo '  ExpiresByType font/woff2 "access plus 1 year"'; \
    echo '</IfModule>'; \
    echo ''; \
    echo '<IfModule mod_deflate.c>'; \
    echo '  AddOutputFilterByType DEFLATE text/plain'; \
    echo '  AddOutputFilterByType DEFLATE text/html'; \
    echo '  AddOutputFilterByType DEFLATE text/xml'; \
    echo '  AddOutputFilterByType DEFLATE text/css'; \
    echo '  AddOutputFilterByType DEFLATE application/xml'; \
    echo '  AddOutputFilterByType DEFLATE application/xhtml+xml'; \
    echo '  AddOutputFilterByType DEFLATE application/rss+xml'; \
    echo '  AddOutputFilterByType DEFLATE application/javascript'; \
    echo '  AddOutputFilterByType DEFLATE application/x-javascript'; \
    echo '</IfModule>'; \
    echo ''; \
    echo '<IfModule mod_headers.c>'; \
    echo '  # CRITICAL FIX: Use SAMEORIGIN instead of DENY for Elementor'; \
    echo '  Header always set X-Frame-Options SAMEORIGIN'; \
    echo '  Header always set X-Content-Type-Options nosniff'; \
    echo '  Header always set X-XSS-Protection "1; mode=block"'; \
    echo '  Header always set Referrer-Policy "strict-origin-when-cross-origin"'; \
    echo '  Header always set Permissions-Policy "geolocation=(), microphone=(), camera=()"'; \
    echo '  Header unset Server'; \
    echo '  Header unset X-Powered-By'; \
    echo '</IfModule>'; \
    } > /etc/apache2/conf-available/performance.conf && \
    a2enconf performance

# Security configurations
RUN { \
    echo 'ServerTokens Prod'; \
    echo 'ServerSignature Off'; \
    echo 'TraceEnable Off'; \
    } >> /etc/apache2/conf-available/security.conf && \
    a2enconf security

# Configure log rotation and redirection for Docker
RUN ln -sf /proc/1/fd/1 /var/log/apache2/access.log && \
    ln -sf /proc/1/fd/2 /var/log/apache2/error.log

# WordPress security - disable file editing and execution
RUN { \
    echo '# WordPress Security'; \
    echo '<Files wp-config.php>'; \
    echo '  order allow,deny'; \
    echo '  deny from all'; \
    echo '</Files>'; \
    echo ''; \
    echo '<Directory /var/www/html/wp-content/uploads/>'; \
    echo '  <Files *.php>'; \
    echo '    deny from all'; \
    echo '  </Files>'; \
    echo '</Directory>'; \
    } > /etc/apache2/conf-available/wordpress-security.conf && \
    a2enconf wordpress-security

# Set working directory
WORKDIR /var/www/html

# Copy custom entrypoint script
COPY ./sh/docker-entrypoint-custom.sh /usr/local/bin/docker-entrypoint-custom.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-custom.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD curl -f http://localhost/wp-admin/admin-ajax.php?action=heartbeat || exit 1

# Expose port
EXPOSE 80 443

# Use custom entrypoint (correct path)
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-custom.sh"]
CMD ["apache2-foreground"]