
#!/bin/bash

set -e

echo "Fixing Apache to serve Laravel panel instead of default page..."

# Remove default Apache page
rm -f /var/www/html/index.html

# Create Apache site configuration
cat > /etc/apache2/sites-available/vpn_panel.conf <<EOF
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    ServerName 185.229.66.97
    DocumentRoot /var/www/vpn_panel/public

    <Directory /var/www/vpn_panel/public>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/vpn_error.log
    CustomLog \${APACHE_LOG_DIR}/vpn_access.log combined
</VirtualHost>
EOF

# Enable the new site and required modules
a2dissite 000-default.conf || true
a2ensite vpn_panel.conf
a2enmod rewrite

# Restart Apache to apply changes
systemctl reload apache2

echo "✅ Apache is now configured to serve Laravel panel at http://185.229.66.97"
