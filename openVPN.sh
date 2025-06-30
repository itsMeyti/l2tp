#!/bin/bash

set -e

echo "=== نصب OpenVPN + پنل دانلود فایل کاربران ==="

# 1. به‌روزرسانی
apt update && apt upgrade -y

# 2. نصب OpenVPN و ابزارها
apt install -y openvpn easy-rsa apache2 php libapache2-mod-php ufw curl unzip

# 3. آماده‌سازی Easy-RSA
make-cadir ~/openvpn-ca
cd ~/openvpn-ca

# 4. پیکربندی CA
sed -i 's/export KEY_NAME="EasyRSA"/export KEY_NAME="server"/' vars
source vars
./clean-all
./build-ca --batch

# 5. ساخت کلیدها
./build-key-server --batch server
./build-dh
openvpn --genkey --secret keys/ta.key

# 6. کپی فایل‌های لازم به OpenVPN
cp -r keys /etc/openvpn
cp ~/openvpn-ca/keys/{server.crt,server.key,ca.crt,dh2048.pem,ta.key} /etc/openvpn

# 7. پیکربندی سرور OpenVPN
cat >/etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh2048.pem
auth SHA256
tls-auth ta.key 0
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
keepalive 10 120
persist-key
persist-tun
status openvpn-status.log
verb 3
explicit-exit-notify 1
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
EOF

# 8. فعال‌سازی NAT
IP=$(curl -s ifconfig.me)
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $(ip r | grep default | awk '{print $5}') -j MASQUERADE
iptables-save > /etc/iptables.rules

# 9. فایروال و UFW
ufw allow 1194/udp
ufw allow OpenSSH
sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
cat >> /etc/ufw/before.rules <<EOF

# START OPENVPN RULES
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 10.8.0.0/24 -o $(ip r | grep default | awk '{print $5}') -j MASQUERADE
COMMIT
# END OPENVPN RULES
EOF
ufw disable && ufw enable

# 10. فعال‌سازی OpenVPN
systemctl enable openvpn@server
systemctl start openvpn@server

# 11. ساخت کلید کاربر client1
cd ~/openvpn-ca
./build-key --batch client1

# 12. ساخت فایل کانفیگ .ovpn
mkdir -p /var/www/html/ovpn-users

cat > /var/www/html/ovpn-users/client1.ovpn <<EOF
client
dev tun
proto udp
remote $IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
cipher AES-256-CBC
key-direction 1
verb 3
<ca>
$(cat keys/ca.crt)
</ca>
<cert>
$(cat keys/client1.crt)
</cert>
<key>
$(cat keys/client1.key)
</key>
<tls-auth>
$(cat keys/ta.key)
</tls-auth>
EOF

chmod -R 644 /var/www/html/ovpn-users/*.ovpn

# 13. ساخت صفحه وب برای دانلود
cat >/var/www/html/index.php <<'EOPHP'
<!DOCTYPE html>
<html lang="fa">
<head>
    <meta charset="UTF-8">
    <title>دانلود فایل‌های VPN</title>
</head>
<body>
    <h2>📥 لیست فایل‌های .ovpn برای کاربران</h2>
    <ul>
<?php
$files = glob("ovpn-users/*.ovpn");
foreach ($files as $file) {
    $name = basename($file);
    echo "<li><a href='$file' download>$name</a></li>";
}
?>
    </ul>
</body>
</html>
EOPHP

chown -R www-data:www-data /var/www/html/ovpn-users

# 14. خروجی نهایی
echo "✅ نصب کامل شد!"
echo "🌐 پنل دانلود فایل کاربران در: http://$IP/"
echo "📁 فایل client1.ovpn در دسترس: http://$IP/ovpn-users/client1.ovpn"
