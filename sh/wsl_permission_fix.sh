#!/bin/bash

# WSL WordPress Docker Permission Fix Script
# Run this script in your WSL environment to set up proper permissions

echo "Setting up WSL permissions for WordPress Docker..."

# Get the current user ID and group ID
USER_ID=$(id -u)
GROUP_ID=$(id -g)

echo "Current User ID: $USER_ID"
echo "Current Group ID: $GROUP_ID"

# Create wp-content directory structure if it doesn't exist
mkdir -p ./wp-content/{plugins,themes,uploads,cache}

# Set permissions for the host directories
echo "Setting up host directory permissions..."

# Make sure the current user owns the directories
sudo chown -R $USER_ID:$GROUP_ID ./wp-content
sudo chmod -R 755 ./wp-content

# Special permissions for uploads
sudo chmod -R 777 ./wp-content/uploads
sudo chmod -R 777 ./wp-content/cache

echo "Creating a permission fix script for ongoing use..."

# Create a script that can be run anytime to fix permissions
cat > ./sh/fix-wp-permissions.sh << 'EOF'
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
EOF

chmod +x ./sh/fix-wp-permissions.sh

echo "Setting up WSL-specific configurations..."

# Add to .wslconfig if it doesn't exist
WSLCONFIG_PATH="$USERPROFILE/.wslconfig"
if [ ! -f "$WSLCONFIG_PATH" ]; then
    echo "Creating .wslconfig file..."
    cat > "$USERPROFILE/.wslconfig" << 'EOF'
[wsl2]
memory=4GB
processors=2

[automount]
enabled=true
options="metadata,uid=1000,gid=1000,umask=022,fmask=011,dmask=000"
EOF
    echo ".wslconfig created. Please restart WSL after this script completes."
fi

echo "Setting up automatic permission fixing..."

# Create a systemd service file for automatic permission fixing (if systemd is available)
if command -v systemctl >/dev/null 2>&1; then
    sudo tee /etc/systemd/user/wordpress-permissions.service > /dev/null << EOF
[Unit]
Description=Fix WordPress permissions periodically
After=network.target

[Service]
Type=oneshot
ExecStart=$(pwd)/sh/fix-wp-permissions.sh
WorkingDirectory=$(pwd)

[Install]
WantedBy=default.target
EOF

    sudo tee /etc/systemd/user/wordpress-permissions.timer > /dev/null << EOF
[Unit]
Description=Run WordPress permission fix every 30 minutes
Requires=wordpress-permissions.service

[Timer]
OnCalendar=*:0/30
Persistent=true

[Install]
WantedBy=timers.target
EOF

    echo "Systemd service created. Enable it with:"
    echo "systemctl --user enable wordpress-permissions.timer"
    echo "systemctl --user start wordpress-permissions.timer"
fi

echo "Creating helpful aliases..."

# Add helpful aliases to .bashrc
cat >> ~/.bashrc << 'EOF'

# WordPress Docker aliases
alias wp-fix-perms='./sh/fix-wp-permissions.sh'
alias wp-up='docker-compose up -d'
alias wp-down='docker-compose down'
alias wp-logs='docker-compose logs -f wordpress'
alias wp-cli='docker-compose exec wordpress wp --allow-root'
EOF

echo ""
echo "✅ WSL Permission setup complete!"
echo ""
echo "What was set up:"
echo "1. Host directory permissions fixed"
echo "2. Created fix-wp-permissions.sh script for ongoing use"
echo "3. Created docker-compose.override.yml for WSL compatibility"
echo "4. Added helpful bash aliases"
echo ""
echo "Next steps:"
echo "1. Run 'source ~/.bashrc' to load new aliases"
echo "2. Run 'docker-compose up -d' to start your WordPress site"
echo "3. Use 'wp-fix-perms' anytime you have permission issues"
echo "4. If you created .wslconfig, restart WSL: 'wsl --shutdown' then reopen"
echo ""
echo "Common commands:"
echo "  wp-up          - Start WordPress"
echo "  wp-down        - Stop WordPress"  
echo "  wp-fix-perms   - Fix permissions"
echo "  wp-logs        - View logs"
echo "  wp-cli         - Run WP-CLI commands"
echo ""