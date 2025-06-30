#!/bin/bash

set -e

echo "=== نصب OpenConnect VPN (ocserv) همراه با پنل مدیریت تحت وب ==="

# 1. به‌روزرسانی سیستم
apt update && apt upgrade -y

# 2. نصب ocserv و Apache + PHP
apt install -y ocserv apache2 php libapache2-mod-php php-cli unzip wget nano

# 3. فعال‌سازی ocserv
systemctl enable ocserv
systemctl start ocserv

# 4. پیکربندی ocserv
cat >/etc/ocserv/ocserv.conf <<EOF
auth = "plain[passwd=/etc/ocserv/ocpasswd]"
tcp-port = 443
udp-port = 443
max-clients = 50
max-same-clients = 10
server-cert = /etc/ssl/certs/ssl-cert-snakeoil.pem
server-key = /etc/ssl/private/ssl-cert-snakeoil.key
ipv4-network = 192.168.129.0
ipv4-netmask = 255.255.255.0
default-domain = vpn.local
dns = 1.1.1.1
keepalive = 32400
try-mtu-discovery = false
compression = true
no-route = 10.0.0.0/8
no-route = 192.168.0.0/16
EOF

# 5. ساخت فایل پسورد کاربران اولیه
touch /etc/ocserv/ocpasswd
chmod 600 /etc/ocserv/ocpasswd

# 6. راه‌اندازی مجدد ocserv
systemctl restart ocserv

# 7. نصب پنل مدیریت تحت وب (ساده)
mkdir -p /var/www/html/vpnadmin

cat >/var/www/html/vpnadmin/index.php <<'EOPHP'
<!DOCTYPE html>
<html>
<head>
  <title>پنل مدیریت VPN</title>
  <meta charset="UTF-8">
</head>
<body>
  <h2>افزودن کاربر جدید</h2>
  <form method="POST">
    <input name="username" placeholder="نام کاربری" required><br>
    <input name="password" placeholder="رمز عبور" required type="password"><br>
    <button type="submit">ایجاد کاربر</button>
  </form>
  <hr>
<?php
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $u = escapeshellarg($_POST['username']);
    $p = escapeshellarg($_POST['password']);
    $cmd = "echo $p | ocpasswd -c /etc/ocserv/ocpasswd -d $u >/dev/null 2>&1 || echo $p | ocpasswd -c /etc/ocserv/ocpasswd $u";
    system($cmd);
    echo "<p>✅ کاربر با موفقیت ثبت شد</p>";
}
?>
</body>
</html>
EOPHP

# 8. تنظیم دسترسی
chown -R www-data:www-data /var/www/html/vpnadmin

# 9. راه‌اندازی Apache
systemctl enable apache2
systemctl restart apache2

# 10. نمایش اطلاعات دسترسی پنل
IP=$(curl -s ifconfig.me)
echo "✅ نصب کامل شد!"
echo "🌐 آدرس پنل: http://$IP/vpnadmin"
echo "👤 برای ساخت کاربران جدید از همین پنل استفاده کن"
