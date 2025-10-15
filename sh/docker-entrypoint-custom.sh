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

# Function to wait for database with MUCH shorter timeout
wait_for_db() {
    if [ -n "${WORDPRESS_DB_HOST:-}" ]; then
        local db_host="${WORDPRESS_DB_HOST%:*}"  # Remove port if present
        local db_port="${WORDPRESS_DB_HOST#*:}"  # Extract port if present
        db_port="${db_port:-3306}"  # Default to 3306 if no port specified
        
        echo "Waiting for database connection at $db_host:$db_port (max 30 seconds)..."
        echo "Using user: ${WORDPRESS_DB_USER}"
        echo "Database: ${WORDPRESS_DB_NAME}"
        
        local max_attempts=6  # 6 attempts × 5 seconds = 30 seconds max
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            # Test basic TCP connection first
            if nc -z -w 2 "$db_host" "$db_port" 2>/dev/null; then
                echo "Database port is open, testing MySQL authentication..."
                
                # Test MySQL connection with simpler command
                if mysql \
                    -h"$db_host" \
                    -P"$db_port" \
                    -u"${WORDPRESS_DB_USER}" \
                    -p"${WORDPRESS_DB_PASSWORD}" \
                    --connect-timeout=3 \
                    --ssl-mode=DISABLED \
                    -e "SELECT 1;" >/dev/null 2>&1; then
                    
                    echo "Database connection successful!"
                    return 0
                else
                    echo "MySQL is up but authentication failed, waiting..."
                fi
            else
                echo "Database port not open yet..."
            fi
            
            echo "Attempt $attempt/$max_attempts - Database not ready, sleeping 5 seconds..."
            sleep 5
            attempt=$((attempt + 1))
        done
        
        echo "WARNING: Could not establish database connection after $max_attempts attempts (30 seconds)"
        echo "This might be OK if MySQL is still initializing..."
        return 1
    else
        echo "WARNING: WORDPRESS_DB_HOST not set, skipping database wait"
        return 0
    fi
}

# Function to wait for Redis if configured
wait_for_redis() {
    if [ -n "${REDIS_HOST:-}" ]; then
        echo "Waiting for Redis connection at ${REDIS_HOST}:${REDIS_PORT:-6379}..."
        local max_attempts=5
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            if timeout 2 redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT:-6379}" ping >/dev/null 2>&1; then
                echo "Redis is ready!"
                return 0
            else
                echo "Attempt $attempt/$max_attempts - Redis is unavailable - sleeping 2 seconds..."
                sleep 2
                attempt=$((attempt + 1))
            fi
        done
        
        echo "WARNING: Could not connect to Redis after $max_attempts attempts, continuing without Redis..."
        return 1
    fi
}

# Function to check if WordPress is ready - FIXED
wait_for_wordpress() {
    echo "Waiting for WordPress to be ready..."
    local max_attempts=5
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Check if WordPress is installed and database connection works
        if wp core is-installed --allow-root --path=/var/www/html 2>/dev/null; then
            echo "WordPress is installed and ready!"
            return 0
        fi
        
        # Check if we can connect to database (WordPress might not be installed yet)
        if wp db check --allow-root --path=/var/www/html 2>/dev/null; then
            echo "WordPress database is connected but not installed yet"
            return 0
        fi
        
        # Check if wp-config.php exists (installation might be in progress)
        if [ -f "/var/www/html/wp-config.php" ]; then
            echo "WordPress configuration exists, installation likely in progress..."
            return 0
        fi
        
        echo "Attempt $attempt/$max_attempts - WordPress not ready yet, waiting 3 seconds..."
        sleep 3
        attempt=$((attempt + 1))
    done
    
    echo "WARNING: WordPress failed to become ready after $max_attempts attempts, but continuing..."
    return 1
}

# Function to setup Redis cache plugin with better error handling
setup_redis_cache() {
    echo "Setting up Redis cache plugin..."
    
    # Check if Redis is actually available
    if ! timeout 2 redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT:-6379}" ping >/dev/null 2>&1; then
        echo "WARNING: Redis server not accessible, skipping Redis cache setup"
        return 1
    fi
    
    # Check if WordPress is installed
    if ! wp core is-installed --allow-root --path=/var/www/html 2>/dev/null; then
        echo "WARNING: WordPress not installed yet, skipping Redis cache setup"
        return 1
    fi
    
    # Install and activate Redis cache plugin
    if ! wp plugin is-installed redis-cache --allow-root --path=/var/www/html 2>/dev/null; then
        echo "Installing Redis Cache plugin..."
        if ! wp plugin install redis-cache --allow-root --path=/var/www/html; then
            echo "WARNING: Failed to install Redis Cache plugin"
            return 1
        fi
    fi
    
    # Activate the plugin
    if ! wp plugin is-active redis-cache --allow-root --path=/var/www/html 2>/dev/null; then
        echo "Activating Redis Cache plugin..."
        if ! wp plugin activate redis-cache --allow-root --path=/var/www/html; then
            echo "WARNING: Failed to activate Redis Cache plugin"
            return 1
        fi
    fi
    
    # Enable Redis cache
    echo "Enabling Redis cache..."
    if wp redis enable --allow-root --path=/var/www/html; then
        echo "Redis Cache plugin installed, activated, and enabled"
        return 0
    else
        echo "WARNING: Redis Cache plugin installed but failed to enable"
        return 1
    fi
}

# Function to handle shutdown gracefully
cleanup() {
    echo "Received shutdown signal, stopping services..."
    # Stop Apache gracefully
    if [ -n "$APACHE_PID" ]; then
        echo "Stopping Apache..."
        kill -TERM "$APACHE_PID" 2>/dev/null || true
        # Wait for process to finish
        wait "$APACHE_PID" 2>/dev/null || true
    fi
    exit 0
}

# Main execution
main() {
    echo "WordPress Docker Container Starting..."
    
    # Set up signal handlers early
    trap cleanup SIGTERM SIGINT
    
    # Fix permissions first
    fix_wordpress_permissions
    
    # Create a cron job to periodically fix permissions (every 30 minutes)
    echo "*/30 * * * * root /usr/local/bin/fix-permissions-cron.sh" > /etc/cron.d/wordpress-permissions
    chmod 0644 /etc/cron.d/wordpress-permissions
    
    # Create the cron script
    cat > /usr/local/bin/fix-permissions-cron.sh << 'EOF'
#!/bin/bash
# Cron script to maintain WordPress permissions
echo "$(date): Running permission fix cron job"
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
    
    # Wait for dependencies with SHORT timeouts
    echo "Starting dependency checks..."
    if ! wait_for_db; then
        echo "WARNING: Database connection failed after 30 seconds, but continuing..."
    fi
    
    wait_for_redis
    
    # Start the original WordPress entrypoint in background
    echo "Starting WordPress entrypoint..."
    docker-entrypoint.sh apache2-foreground &
    APACHE_PID=$!
    
    # Give Apache time to start
    sleep 3
    
    # Wait for WordPress to be ready
    if wait_for_wordpress; then
        echo "WordPress is ready or in installation state."
        
        # Try to setup Redis cache, but don't fail if it doesn't work
        if setup_redis_cache; then
            echo "Redis cache configured successfully."
        else
            echo "Redis cache setup skipped or failed, but continuing..."
        fi
        
        # Re-apply permissions after plugin setup
        fix_wordpress_permissions
        
        echo "WordPress setup completed successfully!"
    else
        echo "WARNING: WordPress setup had issues, but continuing container operation..."
    fi
    
    echo "WordPress container is fully operational!"
    
    # Wait for the Apache process to finish
    wait $APACHE_PID
}

# Run main function with all arguments
main "$@"