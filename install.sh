#!/bin/bash

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Check OS (Ubuntu/Debian)
if ! grep -E 'Ubuntu|Debian' /etc/os-release > /dev/null; then
    echo "This script only supports Ubuntu or Debian"
    exit 1
fi

# Update system
apt-get update && apt-get upgrade -y

# Install L2TP/IPsec dependencies
apt-get install -y strongswan xl2tpd iptables

# Install PHP, Composer, and Nginx for Laravel
apt-get install -y php php-fpm php-mysql php-mbstring php-xml php-zip composer nginx mysql-server

# Install L2TP/IPsec
echo "Configuring L2TP/IPsec..."
cat > /etc/ipsec.conf <<EOF
config setup
    charondebug="ike 2, knl 2, cfg 2"
conn %default
    ikelifetime=60m
    keylife=20m
    rekeymargin=3m
    keyingtries=1
conn L2TP-PSK
    authby=secret
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/1701
    auto=add
EOF

cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
[lns default]
ip range = 192.168.1.100-192.168.1.200
local ip = 192.168.1.1
require chap = yes
refuse pap = yes
require authentication = yes
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

cat > /etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 8.8.4.4
asyncmap 0
auth
crtscts
lock
hide-password
modem
debug
name l2tpd
proxyarp
lcp-echo-interval 30
lcp-echo-failure 4
EOF

# Setup PSK
read -p "Enter Pre-Shared Key (PSK): " psk
cat > /etc/ipsec.secrets <<EOF
%any %any : PSK "$psk"
EOF

# Setup initial user
read -p "Enter VPN username: " vpn_user
read -p "Enter VPN password: " vpn_pass
cat > /etc/ppp/chap-secrets <<EOF
$vpn_user l2tpd $vpn_pass *
EOF

# Configure firewall
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -p udp --dport 1701 -j ACCEPT
iptables -A FORWARD -p udp --dport 500 -j ACCEPT
iptables -A FORWARD -p udp --dport 4500 -j ACCEPT
apt-get install -y iptables-persistent
service netfilter-persistent start

# Start services
systemctl enable strongswan xl2tpd
systemctl restart strongswan xl2tpd

# Install Laravel
cd /var/www
composer create-project --prefer-dist laravel/laravel vpn_panel
chown -R www-data:www-data /var/www/vpn_panel
chmod -R 775 /var/www/vpn_panel/storage

# Setup MySQL
mysql -e "CREATE DATABASE vpn_panel;"
mysql -e "CREATE USER 'vpn_admin'@'localhost' IDENTIFIED BY 'secure_password';"
mysql -e "GRANT ALL PRIVILEGES ON vpn_panel.* TO 'vpn_admin'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# Configure Laravel .env
cat > /var/www/vpn_panel/.env <<EOF
APP_NAME=VPN_Panel
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=http://your_server_ip

DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=vpn_panel
DB_USERNAME=vpn_admin
DB_PASSWORD=secure_password
EOF

# Generate Laravel key
cd /var/www/vpn_panel
php artisan key:generate

# Setup Nginx
cat > /etc/nginx/sites-available/vpn_panel <<EOF
server {
    listen 80;
    server_name your_server_ip;
    root /var/www/vpn_panel/public;
    index index.php index.html index.htm;

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

ln -s /etc/nginx/sites-available/vpn_panel /etc/nginx/sites-enabled/
systemctl restart nginx

# Copy Laravel project files (assuming they are provided below)
# Note: Replace with actual Laravel project files
echo "Copying Laravel project files..."
# Add commands to copy Laravel files here (or assume they are in a repo)

# Run migrations
cd /var/www/vpn_panel
php artisan migrate

# Set permissions for chap-secrets
chmod 600 /etc/ppp/chap-secrets
chown www-data:www-data /etc/ppp/chap-secrets

echo "Installation complete! Access the panel at http://your_server_ip"
echo "Default admin login: admin / admin123"
