#!/bin/bash
# One-time installer for Tunnel's FULL VPN mode. Run with: sudo bash ~/.local/xray/install-vpn.sh
# - copies sing-box + config to a root-owned folder (so it can't be tampered with)
# - adds a LaunchDaemon (NOT started at boot; only when you flip the switch)
# - lets YOUR user start/stop exactly that daemon without a password (nothing else)
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
U="${SUDO_USER:?run via sudo}"
H=$(eval echo "~$U")
mkdir -p /usr/local/libexec/tunnel
install -o root -g wheel -m 755 "$H/.local/xray/sing-box" /usr/local/libexec/tunnel/sing-box
install -o root -g wheel -m 600 "$H/.local/xray/tun.json" /usr/local/libexec/tunnel/tun.json
cat > /Library/LaunchDaemons/local.tunnel.vpn.plist <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.tunnel.vpn</string>
  <key>ProgramArguments</key><array><string>/usr/local/libexec/tunnel/sing-box</string><string>run</string><string>-c</string><string>/usr/local/libexec/tunnel/tun.json</string></array>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/tunnel-vpn.log</string>
</dict></plist>
P
chown root:wheel /Library/LaunchDaemons/local.tunnel.vpn.plist
chmod 644 /Library/LaunchDaemons/local.tunnel.vpn.plist
cat > /etc/sudoers.d/tunnel-vpn <<S
$U ALL=(root) NOPASSWD: /bin/launchctl bootstrap system /Library/LaunchDaemons/local.tunnel.vpn.plist, /bin/launchctl bootout system/local.tunnel.vpn
S
chmod 440 /etc/sudoers.d/tunnel-vpn
visudo -cf /etc/sudoers.d/tunnel-vpn
echo "FULL VPN mode installed. Use the switch in Tunnel.app."
