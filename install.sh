#!/usr/bin/env bash
# Tunnel — one-command macOS installer.
#
#   curl -fsSL https://raw.githubusercontent.com/bulgogi-ily/tunnel/main/install.sh | bash -s -- 'vless://...'
#
# The vless:// link is printed by server/install-server.sh. Everything else (Xray, sing-box,
# Tunnel.app) is downloaded from this repo's GitHub Release and checked against SHA256SUMS.
set -euo pipefail

REPO="bulgogi-ily/tunnel"
DEST="$HOME/.local/xray"
REL="https://github.com/$REPO/releases/latest/download"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "This installer is for macOS. For the server, use server/install-server.sh."

# ---------- 1. connection link ----------
LINK="${1:-${TUNNEL_LINK:-}}"
if [ -z "$LINK" ]; then
  [ -r /dev/tty ] || die "Pass your vless:// link as an argument."
  read -r -p "Paste your vless:// link (printed by the server installer): " LINK </dev/tty
fi
[[ "$LINK" == vless://* ]] || die "That doesn't look like a vless:// link."

rest=${LINK#vless://}; rest=${rest%%#*}
UUID=${rest%%@*}
hostport=${rest#*@}; hostport=${hostport%%\?*}
SERVER=${hostport%:*}; PORT=${hostport##*:}
query="&${rest#*\?}"
q() { printf '%s' "$query" | sed -n "s/.*&$1=\([^&]*\).*/\1/p"; }
PUBKEY=$(q pbk); SID=$(q sid); SNI=$(q sni)
for v in UUID SERVER PORT PUBKEY SID SNI; do [ -n "${!v}" ] || die "Link is missing '$v'."; done
say "Server $SERVER:$PORT (camouflage: $SNI)"

# ---------- 2. download bundle ----------
case "$(uname -m)" in
  arm64)  ARCH=arm64 ;;
  x86_64) ARCH=x86_64 ;;
  *) die "Unsupported Mac architecture $(uname -m)" ;;
esac
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
say "Downloading tunnel-macos-$ARCH.zip from $REPO"
curl -fL --progress-bar -o "$TMP/bundle.zip" "$REL/tunnel-macos-$ARCH.zip"
curl -fsSL -o "$TMP/SHA256SUMS" "$REL/SHA256SUMS"
want=$(grep " tunnel-macos-$ARCH.zip\$" "$TMP/SHA256SUMS" | awk '{print $1}')
got=$(shasum -a 256 "$TMP/bundle.zip" | awk '{print $1}')
[ -n "$want" ] && [ "$want" = "$got" ] || die "Checksum mismatch — download corrupted or tampered with."
say "Checksum OK"
ditto -x -k "$TMP/bundle.zip" "$TMP"
B="$TMP/tunnel-macos-$ARCH"

# ---------- 3. install files ----------
say "Installing to $DEST and ~/Applications/Tunnel.app"
mkdir -p "$DEST" "$HOME/Applications" "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/local.xray.client" 2>/dev/null || true
cp "$B/bin/xray" "$B/bin/sing-box" "$B/bin/geoip.dat" "$B/bin/geosite.dat" "$DEST/"
cp "$B/scripts/install-vpn.sh" "$DEST/install-vpn.sh"
cp -R "$B/licenses" "$DEST/"
rm -rf "$HOME/Applications/Tunnel.app"; cp -R "$B/Tunnel.app" "$HOME/Applications/"
xattr -cr "$DEST" "$HOME/Applications/Tunnel.app" 2>/dev/null || true
chmod +x "$DEST/xray" "$DEST/sing-box"

# ---------- 4. configs ----------
cat > "$DEST/config.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": true}},
    {"tag": "http",  "listen": "127.0.0.1", "port": 10809, "protocol": "http"}
  ],
  "outbounds": [{
    "tag": "proxy", "protocol": "vless",
    "settings": {"vnext": [{"address": "$SERVER", "port": $PORT,
      "users": [{"id": "$UUID", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true},
      "realitySettings": {"serverName": "$SNI", "fingerprint": "chrome", "publicKey": "$PUBKEY", "shortId": "$SID"}
    }
  }]
}
EOF

# Keep the tunnel's own connection to the server out of the TUN (by IP when we have one).
if [[ "$SERVER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then SERVER_IP=$SERVER
else SERVER_IP=$(dig +short "$SERVER" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1 || true); fi
IP_RULE=""; [ -n "${SERVER_IP:-}" ] && IP_RULE="{\"ip_cidr\": [\"$SERVER_IP/32\"], \"outbound\": \"direct\"},"

cat > "$DEST/tun.json" <<EOF
{
  "log": {"level": "warn"},
  "dns": {
    "servers": [
      {"type": "https", "tag": "remote", "server": "1.1.1.1", "detour": "proxy"},
      {"type": "local", "tag": "local"}
    ],
    "final": "remote"
  },
  "inbounds": [
    {"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "mtu": 1500,
     "auto_route": true, "strict_route": true, "stack": "mixed"}
  ],
  "outbounds": [
    {"type": "socks", "tag": "proxy", "server": "127.0.0.1", "server_port": 10808, "version": "5"},
    {"type": "direct", "tag": "direct"}
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": "local",
    "rules": [
      $IP_RULE
      {"process_name": ["xray"], "outbound": "direct"},
      {"action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"ip_is_private": true, "outbound": "direct"}
    ],
    "final": "proxy"
  }
}
EOF
chmod 600 "$DEST/config.json" "$DEST/tun.json"
"$DEST/xray" run -test -config "$DEST/config.json" >/dev/null || die "Xray rejected the config."
"$DEST/sing-box" check -c "$DEST/tun.json" || die "sing-box rejected the VPN config."

# ---------- 5. proxy launch agent ----------
PL="$HOME/Library/LaunchAgents/local.xray.client.plist"
cat > "$PL" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.xray.client</string>
  <key>ProgramArguments</key><array><string>$DEST/xray</string><string>run</string><string>-config</string><string>$DEST/config.json</string></array>
  <key>EnvironmentVariables</key><dict><key>XRAY_LOCATION_ASSET</key><string>$DEST</string></dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$DEST/xray.log</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PL"
sleep 2
say "Testing tunnel…"
EXIT_IP=$(curl -s --max-time 10 --socks5-hostname 127.0.0.1:10808 https://api.ipify.org || true)
if [ -n "$EXIT_IP" ]; then say "Proxy works — traffic exits at $EXIT_IP"
else printf '\033[33mProxy test failed. Check the server is running and TCP %s is open in its cloud firewall.\033[0m\n' "$PORT"; fi

# ---------- 6. optional full-VPN mode ----------
ans=n
if [ -r /dev/tty ]; then
  read -r -p "Install FULL VPN mode too (routes every app, incl. games/VNC; needs your Mac password)? [y/N] " ans </dev/tty || true
fi
if [[ "$ans" =~ ^[Yy] ]]; then sudo bash "$DEST/install-vpn.sh"
else echo "Skipped. Later: sudo bash $DEST/install-vpn.sh"; fi

open "$HOME/Applications/Tunnel.app" || true
cat <<EOF

Done!
  App:    ~/Applications/Tunnel.app
  Proxy:  socks5://127.0.0.1:10808   http://127.0.0.1:10809   (starts at login)
EOF
