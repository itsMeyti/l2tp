#!/bin/bash

# Colors
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo -e "${GREEN}Starting L2TP/IPSec VPN installation...${NC}"

# Install required packages
apt update && apt install -y strongswan xl2tpd ppp lsof ufw

# Configure /etc/ipsec.conf
cat > /etc/ipsec.conf << EOF
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

# Configure /etc/ipsec.secrets
cat > /etc/ipsec.secrets << EOF
: PSK "YourStrongPreSharedKey"
EOF

# Configure /etc/xl2tpd/xl2tpd.conf
cat > /etc/xl2tpd/xl2tpd.conf << EOF
[global]
port = 1701

[lns default]
ip range = 192.168.10.10-192.168.10.100
local ip = 192.168.10.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
ppp debug = yes
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# Configure /etc/ppp/options.xl2tpd
cat > /etc/ppp/options.xl2tpd << EOF
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

# Create default VPN user
cat > /etc/ppp/chap-secrets << EOF
vpnuser  *  StrongUserPassword  *
EOF

# Enable IP forwarding
sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

# Set up iptables NAT rules
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables-save > /etc/iptables.rules

# Create auto-load script for iptables rules
cat > /etc/network/if-pre-up.d/iptables << EOF
#!/bin/sh
iptables-restore < /etc/iptables.rules
EOF
chmod +x /etc/network/if-pre-up.d/iptables

# Restart and enable services
systemctl restart strongswan
systemctl restart xl2tpd
systemctl enable strongswan
systemctl enable xl2tpd

echo -e "${GREEN}✅ VPN installation completed successfully!${NC}"
echo "Use the following credentials to connect:"
echo "----------------------------------------"
echo "Server IP   : YOUR_SERVER_IP"
echo "Username    : vpnuser"
echo "Password    : StrongUserPassword"
echo "PSK (shared key): YourStrongPreSharedKey"
