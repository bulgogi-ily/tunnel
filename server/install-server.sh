#!/usr/bin/env bash
# install-server.sh — set up an Xray VLESS + REALITY server on Ubuntu/Debian.
#
#   curl -fsSL https://raw.githubusercontent.com/bulgogi-ily/tunnel/main/server/install-server.sh | sudo bash
#   curl -fsSL .../install-server.sh | sudo SNI=www.apple.com PORT=443 bash     # custom camouflage/port
#
# Generates a fresh UUID, x25519 key pair and short ID, installs a systemd service,
# opens the port in iptables, and prints the values you need for the client.
set -euo pipefail

SNI="${SNI:-www.microsoft.com}"
PORT="${PORT:-443}"

[ "$(id -u)" = 0 ] || { echo "Run as root (sudo)."; exit 1; }

case "$(uname -m)" in
  x86_64)  ASSET="xray-linux-x86_64.zip" ;;
  aarch64) ASSET="xray-linux-arm64.zip" ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

echo "==> Installing dependencies"
if command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl unzip openssl >/dev/null
elif command -v dnf >/dev/null; then dnf install -y -q curl unzip openssl >/dev/null; fi

echo "==> Downloading Xray (from the Tunnel GitHub release)"
REL="https://github.com/bulgogi-ily/tunnel/releases/latest/download"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$ASSET" "$REL/$ASSET"
curl -fsSL -o "$TMP/SHA256SUMS" "$REL/SHA256SUMS"
(cd "$TMP" && grep " $ASSET\$" SHA256SUMS | sha256sum -c --quiet -) || { echo "Checksum mismatch"; exit 1; }
mv "$TMP/$ASSET" "$TMP/x.zip"
unzip -q "$TMP/x.zip" -d "$TMP"
install -m 755 "$TMP/xray" /usr/local/bin/xray
mkdir -p /usr/local/share/xray /usr/local/etc/xray
cp "$TMP/geoip.dat" "$TMP/geosite.dat" /usr/local/share/xray/
echo "    $(/usr/local/bin/xray version | head -1)"

echo "==> Generating credentials"
UUID=$(xray uuid)
KEYS=$(xray x25519)
# Newer Xray prints "PrivateKey:/Password:", older prints "Private key:/Public key:"
PRIV=$(echo "$KEYS" | grep -iE '^private' | awk -F': *' '{print $2}')
PUB=$(echo "$KEYS"  | grep -iE '^(public|password)' | head -1 | awk -F': *' '{print $2}')
SID=$(openssl rand -hex 8)

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0", "port": $PORT, "protocol": "vless",
    "settings": {"clients": [{"id": "$UUID", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true},
      "realitySettings": {
        "dest": "$SNI:443",
        "serverNames": ["$SNI"],
        "privateKey": "$PRIV",
        "shortIds": ["$SID"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}, {"protocol": "blackhole", "tag": "block"}]
}
EOF
chown root:"$(id -gn nobody)" /usr/local/etc/xray/config.json
chmod 640 /usr/local/etc/xray/config.json

cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray VLESS REALITY
After=network-online.target
Wants=network-online.target

[Service]
User=nobody
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF

echo "==> Tuning network (BBR, TCP Fast Open)"
printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\nnet.ipv4.tcp_fastopen=3\n' > /etc/sysctl.d/99-tunnel.conf
sysctl -q --system

echo "==> Opening port $PORT/tcp in iptables"
if command -v iptables >/dev/null; then
  iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT
  command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || true
fi

systemctl daemon-reload
systemctl enable --now xray >/dev/null 2>&1
sleep 1
systemctl is-active --quiet xray || { echo "xray failed to start:"; journalctl -u xray -n 20 --no-pager; exit 1; }

IP=$(curl -fsS --max-time 5 https://api.ipify.org || echo YOUR_SERVER_IP)
LINK="vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#tunnel"
cat <<EOF

==================== DONE ====================
Server is running. Your connection link (KEEP PRIVATE - anyone with it can use your server):

  $LINK

On your Mac, run:

  curl -fsSL https://raw.githubusercontent.com/bulgogi-ily/tunnel/main/install.sh | bash -s -- '$LINK'

(The link also works in v2rayN, Shadowrocket, Hiddify, v2rayNG, etc.)

Cloud firewall: also allow inbound TCP $PORT in your provider's
security list / security group (e.g. Oracle Cloud VCN Security List).
==============================================
EOF
