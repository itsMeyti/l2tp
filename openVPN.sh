#!/bin/bash

set -e

# =======================
# OpenVPN + Web UI Installer Script
# =======================

# Function to print colored messages
print_info() {
    echo -e "\033[1;32m[INFO]\033[0m $1"
}

print_info "Updating system packages..."
apt update && apt upgrade -y

print_info "Installing OpenVPN, Easy-RSA, Apache, PHP, and UFW..."
apt install -y openvpn easy-rsa apache2 php libapache2-mod-php ufw curl unzip

# Setup Easy-RSA
print_info "Setting up Easy-RSA..."
make-cadir ~/openvpn-ca
cd ~/openvpn-ca

sed -i 's/export KEY_NAME="EasyRSA"/export KEY_NAME="server"/' vars
source vars
./clean-all
./build-ca --batch
./build-key-server --batch server
./build-dh
openvpn --genkey --secret keys/ta.key

# Copy keys to OpenVPN directory
cp -r keys /etc/openvpn
cp ~/openvpn-ca/keys/{server.crt,server.key,ca.crt,dh2048.pem,ta.key} /etc/openvpn

# OpenVPN Server Configuration
print_info "Configuring OpenVPN server..."
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

# Enable NAT
IP=$(curl -s ifconfig.me)
print_info "Enabling IP forwarding and NAT..."
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf

iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $(ip r | grep default | awk '{print $5}') -j MASQUERADE
iptables-save > /etc/iptables.rules

# UFW Configuration
print_info "Configuring UFW firewall..."
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

# Start OpenVPN
print_info "Starting OpenVPN service..."
systemctl enable openvpn@server
systemctl start openvpn@server

# Create Web UI Directory
print_info "Creating user panel directory..."
mkdir -p /var/www/html/vpn-users

# Web UI for managing users
print_info "Setting up basic web UI for user management..."
cat >/var/www/html/index.php <<'EOPHP'
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>VPN User Management</title>
</head>
<body>
  <h2>Create New VPN User</h2>
  <form method="POST">
    <input name="username" placeholder="Username" required><br>
    <button type="submit">Create .ovpn File</button>
  </form>
  <hr>
  <h3>Available Config Files:</h3>
  <ul>
  <?php
  if ($_SERVER['REQUEST_METHOD'] === 'POST') {
      $user = preg_replace('/[^a-zA-Z0-9_]/', '', $_POST['username']);
      if ($user) {
          shell_exec("cd /root/openvpn-ca && source vars && ./build-key --batch $user");
          $ip = trim(shell_exec("curl -s ifconfig.me"));
          $ovpn = "/var/www/html/vpn-users/$user.ovpn";
          $conf = "client\ndev tun\nproto udp\nremote $ip 1194\nresolv-retry infinite\nnobind\npersist-key\npersist-tun\nremote-cert-tls server\nauth SHA256\ncipher AES-256-CBC\nkey-direction 1\nverb 3\n";
          $conf .= "<ca>\n".file_get_contents("/etc/openvpn/ca.crt")."</ca>\n";
          $conf .= "<cert>\n".file_get_contents("/etc/openvpn/keys/{$user}.crt")."</cert>\n";
          $conf .= "<key>\n".file_get_contents("/etc/openvpn/keys/{$user}.key")."</key>\n";
          $conf .= "<tls-auth>\n".file_get_contents("/etc/openvpn/ta.key")."</tls-auth>\n";
          file_put_contents($ovpn, $conf);
      }
  }
  foreach (glob("vpn-users/*.ovpn") as $file) {
      echo "<li><a href='$file' download>" . basename($file) . "</a></li>\n";
  }
  ?>
  </ul>
</body>
</html>
EOPHP

chown -R www-data:www-data /var/www/html/vpn-users
chmod -R 644 /var/www/html/vpn-users

# Final Info
print_info "Installation complete!"
echo -e "\033[1;34m[WEB]\033[0m User Panel: http://$IP/"
echo -e "\033[1;34m[INFO]\033[0m Download OVPN files from the panel after creating users."
