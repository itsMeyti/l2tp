
#!/bin/bash

# ========= VPN INSTALLER + CLI + WEB UI =========
# Based on the structure of sockeye44/instavpn
# Compatible with Ubuntu 20.04+ (tested on 24.04)

set -e

# Configuration
VPN_USER="vpnuser"
VPN_PASS="StrongUserPassword"
VPN_PSK="YourStrongPreSharedKey"
WEB_PORT=8080
WEB_DIR="/opt/vpn-ui"
CLI_SCRIPT="/usr/local/bin/vpnctl"

# Colors
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}Installing L2TP/IPsec VPN with CLI and WebUI support...${NC}"

# Install dependencies
apt update && apt install -y strongswan xl2tpd ppp apache2 php curl unzip

# Configure ipsec.conf
cat > /etc/ipsec.conf <<EOF
config setup
  uniqueids=no

conn l2tp-psk
  auto=add
  keyexchange=ikev1
  authby=secret
  type=transport
  left=%defaultroute
  leftprotoport=17/1701
  right=%any
  rightprotoport=17/%any
  ike=aes256-sha1-modp1024!
  esp=aes256-sha1!
EOF

# Configure ipsec.secrets
cat > /etc/ipsec.secrets <<EOF
: PSK "$VPN_PSK"
EOF

# Configure xl2tpd.conf
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lns default]
ip range = 192.168.100.10-192.168.100.100
local ip = 192.168.100.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# Configure PPP options
cat > /etc/ppp/options.xl2tpd <<EOF
require-mschap-v2
ms-dns 8.8.8.8
ms-dns 8.8.4.4
auth
mtu 1200
mru 1200
nodefaultroute
debug
lock
proxyarp
EOF

# Create initial VPN user
echo -e "$VPN_USER	*	$VPN_PASS	*" > /etc/ppp/chap-secrets

# Enable IP forwarding
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i '/net.ipv4.ip_forward/c\net.ipv4.ip_forward=1' /etc/sysctl.conf
sysctl -p

# Enable NAT
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables-save > /etc/iptables.rules

cat > /etc/network/if-pre-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
chmod +x /etc/network/if-pre-up.d/iptables

# Enable services
systemctl restart ipsec
systemctl enable ipsec
systemctl restart xl2tpd
systemctl enable xl2tpd

# Web UI setup
mkdir -p "$WEB_DIR"
cat > "$WEB_DIR/index.php" <<'EOPHP'
<?php
$chap_file = '/etc/ppp/chap-secrets';

function read_users($file) {
    $lines = file($file);
    $users = [];
    foreach ($lines as $line) {
        if (preg_match('/^([\w-]+)\s+\*/', $line, $match)) {
            $users[] = $match[1];
        }
    }
    return $users;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $user = $_POST['username'] ?? '';
    $pass = $_POST['password'] ?? '';
    $action = $_POST['action'] ?? '';
    $users = file($chap_file);
    if ($action === 'add' && $user && $pass) {
        file_put_contents($chap_file, "$user	*	$pass	*
", FILE_APPEND);
    } elseif ($action === 'remove') {
        $new = array_filter($users, fn($l) => !preg_match("/^$user\s+/", $l));
        file_put_contents($chap_file, implode("", $new));
    }
    header("Location: /vpn-ui/");
    exit;
}

$users = read_users($chap_file);
?>
<html><body>
<h2>VPN User Manager</h2>
<form method="POST">
<input name="username" placeholder="Username" required>
<input name="password" placeholder="Password" required>
<button name="action" value="add">Add</button>
<button name="action" value="remove">Remove</button>
</form>
<ul>
<?php foreach ($users as $u) echo "<li>$u</li>"; ?>
</ul>
</body></html>
EOPHP

ln -s "$WEB_DIR" "/var/www/html/vpn-ui"
ufw allow $WEB_PORT
systemctl restart apache2

# CLI tool
cat > "$CLI_SCRIPT" <<'EOSH'
#!/bin/bash
CHAP="/etc/ppp/chap-secrets"

case "$1" in
  add)
    echo -n "Username: "; read u
    echo -n "Password: "; read p
    echo -e "$u	*	$p	*" >> $CHAP
    echo "User added: $u"
    ;;
  del)
    echo -n "Username to delete: "; read u
    sed -i "/^$u\s\+/d" $CHAP
    echo "User deleted: $u"
    ;;
  list)
    awk '{print $1}' $CHAP
    ;;
  *)
    echo "Usage: vpnctl [add|del|list]"
    ;;
esac
EOSH

chmod +x "$CLI_SCRIPT"

# Final message
echo -e "${GREEN}✅ Installation complete!${NC}"
echo "➤ WebUI: http://<your-server-ip>:80/vpn-ui/"
echo "➤ CLI tool: run 'vpnctl [add|del|list]'"
