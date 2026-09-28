#!/bin/sh
set -eu
me=$(ip -4 -o address show dev eth0 | awk '{ split($4, a, "/"); print a[1]; exit }')

cat > /tmp/tinyproxy.conf <<CONF
Port 8888
Listen 0.0.0.0
Timeout 60
LogLevel Connect
LogFile "/tmp/tinyproxy.log"
BasicAuth knotchy s3cr3t
MaxClients 20
CONF
tinyproxy -c /tmp/tinyproxy.conf

microsocks -i 0.0.0.0 -p 1080 -u knotchy -P 's3cr3t' > /tmp/microsocks.log 2>&1 &

umask 077
wg genkey > /tmp/server.key
wg pubkey < /tmp/server.key > /tmp/server.pub
wg genkey > /tmp/client.key
wg pubkey < /tmp/client.key > /tmp/client.pub
WG_I_PREFER_BUGGY_USERSPACE_TO_POLISHED_KMOD=1 wireguard-go wg0
wg set wg0 listen-port 51820 private-key /tmp/server.key \
  peer "$(cat /tmp/client.pub)" allowed-ips 10.99.0.2/32
ip address add 10.99.0.1/24 dev wg0
ip link set dev wg0 up
echo 1 > /proc/sys/net/ipv4/ip_forward
nft -f - <<NFT
table ip nat {
  chain postrouting {
    type nat hook postrouting priority srcnat;
    oifname "eth0" masquerade
  }
}
NFT
cat > /tmp/client.conf <<CONF
[Interface]
PrivateKey = $(cat /tmp/client.key)
Address = 10.99.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $(cat /tmp/server.pub)
AllowedIPs = 0.0.0.0/0
Endpoint = $me:51820
CONF
echo "route-server ready on $me"
exec sleep infinity
