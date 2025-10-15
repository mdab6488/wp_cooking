#!/bin/bash
set -e

echo "Starting WordPress container with permission fixes..."

# Function to fix permissions
fix_wordpress_permissions() {
    echo "Fixing WordPress permissions..."
    
    # Ensure wp-content directory exists
    mkdir -p /var/www/html/wp-content/{plugins,themes,uploads,cache}
    
    # Set ownership for all wp-content
    chown -R www-data:www-data /var/www/html/wp-content
    
    # Set directory permissions
    find /var/www/html/wp-content -type d -exec chmod 755 {} \;
    
    # Set file permissions
    find /var/www/html/wp-content -type f -exec chmod 644 {} \;
    
    # Special permissions for uploads and cache
    chmod -R 755 /var/www/html/wp-content/uploads
    chmod -R 755 /var/www/html/wp-content/cache
    
    # Ensure plugins directory is writable
    chmod -R 755 /var/www/html/wp-content/plugins
    
    # Set proper permissions for wp-config.php if it exists
    if [ -f /var/www/html/wp-config.php ]; then
        chown www-data:www-data /var/www/html/wp-config.php
        chmod 600 /var/www/html/wp-config.php
    fi
    
    echo "WordPress permissions fixed successfully!"
}

# Function to wait for database
wait_for_db() {
    if [ -n "${WORDPRESS_DB_HOST:-}" ]; then
        echo "Waiting for database connection..."
        until mysql -h"${WORDPRESS_DB_HOST}" -u"${WORDPRESS_DB_USER}" -p"${WORDPRESS_DB_PASSWORD}" -e "SELECT 1" >/dev/null 2>&1; do
            echo "Database is unavailable - sleeping..."
            sleep 2
        done
        echo "Database is ready!"
    fi
}

# Function to wait for Redis if configured
wait_for_redis() {
    if [ -n "${REDIS_HOST:-}" ]; then
        echo "Waiting for Redis connection..."
        until redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT:-6379}" ping >/dev/null 2>&1; do
            echo "Redis is unavailable - sleeping..."
            sleep 2
        done
        echo "Redis is ready!"
    fi
}

# Function to check if WordPress is ready
wait_for_wordpress() {
    echo "Waiting for WordPress to be ready..."
    local max_attempts=60
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if wp core is-installed --allow-root --path=/var/www/html 2>/dev/null; then
            echo "WordPress is ready!"
            return 0
        fi
        
        # Check if WordPress files exist but DB not configured yet
        if [ -f "/var/www/html/wp-config.php" ]; then
            if wp db check --allow-root --path=/var/www/html 2>/dev/null; then
                echo "WordPress database is ready!"
                return 0
            fi
        fi
        
        echo "Attempt $attempt/$max_attempts - WordPress not ready yet, waiting 5 seconds..."
        sleep 5
        attempt=$((attempt + 1))
    done
    
    echo "ERROR: WordPress failed to become ready after $max_attempts attempts"
    return 1
}

# Function to setup Redis cache plugin
setup_redis_cache() {
    echo "Setting up Redis cache plugin..."
    
    # Check if Redis server is accessible
    if ! wp redis status --allow-root --path=/var/www/html 2>/dev/null; then
        echo "Redis server not accessible, installing plugin only..."
        if wp plugin install redis-cache --allow-root --path=/var/www/html; then
            wp plugin activate redis-cache --allow-root --path=/var/www/html
            echo "Redis Cache plugin installed and activated"
        else
            echo "WARNING: Failed to install Redis Cache plugin"
        fi
    else
        # Install, activate, and enable Redis cache
        if wp plugin install redis-cache --activate --allow-root --path=/var/www/html; then
            if wp redis enable --allow-root --path=/var/www/html; then
                echo "Redis Cache plugin installed, activated, and enabled"
            else
                echo "WARNING: Redis Cache plugin installed but failed to enable"
            fi
        else
            echo "WARNING: Failed to install Redis Cache plugin"
        fi
    fi
}

# Function to handle shutdown gracefully
cleanup() {
    echo "Received shutdown signal, stopping services..."
    # Stop Apache gracefully
    if [ -n "$APACHE_PID" ]; then
        kill -TERM "$APACHE_PID" 2>/dev/null || true
        wait "$APACHE_PID" 2>/dev/null || true
    fi
    exit 0
}

# Main execution
main() {
    echo "WordPress Docker Container Starting..."
    
    # Wait for dependencies
    wait_for_db
    wait_for_redis
    
    # Fix permissions before WordPress initialization
    fix_wordpress_permissions
    
    # Create a cron job to periodically fix permissions (every 30 minutes)
    echo "*/30 * * * * root /usr/local/bin/fix-permissions-cron.sh" > /etc/cron.d/wordpress-permissions
    chmod 0644 /etc/cron.d/wordpress-permissions
    
    # Create the cron script
    cat > /usr/local/bin/fix-permissions-cron.sh << 'EOF'
#!/bin/bash
# Cron script to maintain WordPress permissions
chown -R www-data:www-data /var/www/html/wp-content
find /var/www/html/wp-content -type d -exec chmod 755 {} \;
find /var/www/html/wp-content -type f -exec chmod 644 {} \;
chmod -R 755 /var/www/html/wp-content/uploads
chmod -R 755 /var/www/html/wp-content/cache
chmod -R 755 /var/www/html/wp-content/plugins
EOF
    chmod +x /usr/local/bin/fix-permissions-cron.sh
    
    # Start cron daemon
    service cron start
    
    # Set up signal handlers
    trap cleanup SIGTERM SIGINT
    
    # Start the original WordPress entrypoint in background
    echo "Starting WordPress..."
    docker-entrypoint.sh apache2-foreground &
    APACHE_PID=$!
    
    # Wait for WordPress to be ready with proper health checking
    if wait_for_wordpress; then
        # Setup Redis cache plugin after WordPress is ready
        setup_redis_cache
        
        # Re-apply permissions after plugin setup
        fix_wordpress_permissions
    else
        echo "ERROR: WordPress startup failed"
        cleanup
        exit 1
    fi
    
    echo "WordPress with Redis cache is ready!"
    
    # Wait for the Apache process to finish
    wait $APACHE_PID
}

# Run main function with all arguments
main "$@"