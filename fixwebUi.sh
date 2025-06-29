
#!/bin/bash

set -e

echo "🔧 Fixing NGINX to serve Laravel panel..."

# Remove default site if exists
rm -f /etc/nginx/sites-enabled/default

# Create NGINX config for Laravel
cat > /etc/nginx/sites-available/vpn_panel <<EOF
server {
    listen 80;
    server_name 185.229.66.97;

    root /var/www/vpn_panel/public;
    index index.php index.html;

    access_log /var/log/nginx/vpn_panel_access.log;
    error_log /var/log/nginx/vpn_panel_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

# Enable the site
ln -sf /etc/nginx/sites-available/vpn_panel /etc/nginx/sites-enabled/vpn_panel

# Test and reload NGINX
nginx -t && systemctl reload nginx

echo "✅ NGINX is now serving your Laravel panel at: http://185.229.66.97"
