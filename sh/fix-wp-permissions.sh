#!/bin/bash
echo "Fixing WordPress permissions..."

# Fix ownership
sudo chown -R $(id -u):$(id -g) ./wp-content

# Fix directory permissions
find ./wp-content -type d -exec chmod 755 {} \;

# Fix file permissions
find ./wp-content -type f -exec chmod 644 {} \;

# Special permissions for uploads and cache
chmod -R 777 ./wp-content/uploads
chmod -R 777 ./wp-content/cache

# Fix permissions inside running Docker container
docker-compose exec wordpress chown -R www-data:www-data /var/www/html/wp-content
docker-compose exec wordpress find /var/www/html/wp-content -type d -exec chmod 755 {} \;
docker-compose exec wordpress find /var/www/html/wp-content -type f -exec chmod 644 {} \;

echo "Permissions fixed!"
