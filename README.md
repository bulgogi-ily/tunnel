# Tunnel

Built to bypass firewalls.

A self-hosted, low-latency tunnel that gets SSH, VNC, games and everything else through restrictive networks that use deep packet inspection (DPI). It comes with a native macOS control app styled like Terminal's **Pro** theme.

**Everything you need is in this repo.** The server binary, the Mac client binaries and the app all come from this repo's [Releases](../../releases), and the installers verify them against SHA-256 checksums. You don't need any other website.

```
 Mac ─► Tunnel.app ─► Xray client ─► VLESS + REALITY ─────────────────► your VPS ─► internet
          │              ▲            (looks like HTTPS to microsoft.com)
          └─ FULL VPN ─► sing-box TUN (captures every app, incl. UDP)
```

---

## Quick start (2 commands)

You need:
- **A Linux VPS.** Oracle Cloud's Always Free tier works great. Ubuntu, Debian, or anything with `apt` or `dnf`, on x86_64 or arm64.
- **A Mac.** Apple Silicon or Intel, macOS 14 or newer.

### 1. On the server

SSH into your VPS and run:

```bash
curl -fsSL https://raw.githubusercontent.com/bulgogi-ily/tunnel/main/server/install-server.sh | sudo bash
```

It installs Xray, generates fresh keys, starts the service, and prints:
- your private `vless://` link
- the exact command to run on your Mac

> **Open the port in your cloud firewall too.** On Oracle Cloud, go to **Networking → Virtual Cloud Networks → your VCN → Security Lists → Default → Add Ingress Rules**, with source `0.0.0.0/0`, protocol **TCP** and destination port **443**. Other providers call this a "security group" or "firewall rule".

### 2. On your Mac

Paste the command the server printed. It looks like this:

```bash
curl -fsSL https://raw.githubusercontent.com/bulgogi-ily/tunnel/main/install.sh | bash -s -- 'vless://…'
```

This installs the following, then tests the tunnel:
- Xray, sing-box and **Tunnel.app**
- the proxy, which starts at login

At the end it asks whether to install **Full VPN** mode, which needs your Mac password once.

That's it. Open **Tunnel** from `~/Applications`.

> If you're already behind the firewall and can't reach your server to set it up, connect through a phone hotspot (or any other network) just for step 1.

---

## Why REALITY instead of Shadowsocks?

DPI firewalls flag "fully encrypted" protocols like Shadowsocks because they look like random bytes. On the network this was built for, TCP connections to the server opened fine but were silently dropped as soon as data flowed. Even SSH failed with `timed out during banner exchange`.

**VLESS + REALITY** performs a real TLS 1.3 handshake that impersonates a big, legitimate site (`www.microsoft.com` by default). To the firewall it looks like ordinary HTTPS. You don't need a domain or a certificate.

## Features

| | |
|---|---|
| **Server installer** | One command sets up Xray (VLESS + REALITY + XTLS Vision) as a systemd service, plus BBR and TCP Fast Open |
| **Proxy mode** | SOCKS5 on `127.0.0.1:10808` and HTTP on `127.0.0.1:10809`, started at login |
| **Full VPN mode** | A sing-box TUN sends *every* app through the tunnel, including games, VNC viewers, SSH clients and UDP traffic, even apps that ignore proxy settings |
| **Tunnel.app** | Native SwiftUI control panel: proxy and VPN toggles, exit IP and latency test, one-click SSH to the server, log viewer |
| **Latency test** | `tests/latency-test.sh` compares no tunnel, proxy and full VPN |

## Latency results

All tests were run from **NA West** (client) to a server in **Oracle Cloud us-sanjose-1**, on the filtered network.

### Test 1: Round trip to the server

| | Result |
|---|---|
| Client → server (TCP connect, 8 runs) | **48 ms** median (45–72 ms) |
| Server → Google | 0.3 ms |

### Test 2: Opening a new HTTPS connection (first-byte time)

This test used the original Shadowsocks setup, before and after the latency tweaks.

| Target | No tunnel | Shadowsocks (default) | Shadowsocks + `no_delay` + TCP Fast Open |
|---|---|---|---|
| Google | ~115 ms | ~300 ms | **~155 ms** |
| Cloudflare | ~140 ms | ~300 ms | — |

### Test 3: VLESS + REALITY through the DPI firewall

| Target | Result |
|---|---|
| Google first byte (5 runs) | 149–163 ms (median **155 ms**) |
| SSH to the server through the tunnel | ✅ works. Plain SSH is blocked (times out). |
| Exit IP | ✅ the server's IP |

### Test 4: Five cities, no tunnel vs. proxy vs. full VPN

Round trip in ms on an already-open HTTPS connection: median of 10, with the best run in brackets.

| City (test server) | No tunnel | Proxy | Full VPN | VPN adds |
|---|---|---|---|---|
| Los Angeles (Vultr) | 39 (37) | 135 (106) | **108** (104) | +69 |
| New York (Vultr NJ) | 73 (72) | 205 (162) | **94** (93) | +21 |
| Texas (Vultr Dallas) | 70 (68) | 127 (75) | **76** (72) | +6 |
| Montreal (OVH BHS) | 88 (66) | 152 (107) | **109** (108) | +21 |
| Toronto (Vultr) | 107 (57) | 112 (83) | **84** (82) | −23* |

\* The filtered network's own connection to Toronto was very uneven (57–107 ms), so that row is mostly noise.

**What this means:**
- **All traffic detours through the server's region.** Destinations near you but far from the server cost the most. Here that's Los Angeles: NA West → San Jose → LA.
- **Destinations further east cost almost nothing,** because going through San Jose is about as fast as the normal route.
- **Pick a VPS region close to you** for the lowest overhead.

Run it yourself: `bash tests/latency-test.sh`

---

## Using it

| Want to… | Do this |
|---|---|
| Make every app work, including games, VNC and SSH | Tunnel.app → **FULL VPN: ON** |
| Tunnel only apps that support proxies | Tunnel.app → **PROXY: ON**, and point the app at SOCKS `127.0.0.1:10808` |
| SSH through the proxy only | `ssh -o ProxyCommand="nc -X 5 -x 127.0.0.1:10808 %h %p" user@host` |
| Send terminal commands through the tunnel | Tunnel.app → **COPY PROXY**, then paste into your shell |
| Use a phone or Windows PC | Import the `vless://` link into v2rayNG, Shadowrocket, Hiddify or v2rayN |

## Repo layout

```
install.sh                 One-command Mac installer (downloads the release bundle)
server/install-server.sh   One-command server installer (Xray VLESS+REALITY)
client/install-vpn.sh      One-time root install for full-VPN mode (also inside the bundle)
gui/Tunnel.swift           SwiftUI control app source
gui/build.sh               Build Tunnel.app from source (needs Xcode Command Line Tools)
tests/latency-test.sh      No tunnel vs. proxy vs. full VPN latency test
```

### What's in each release

| Asset | Contents |
|---|---|
| `tunnel-macos-arm64.zip` / `tunnel-macos-x86_64.zip` | `Tunnel.app` (universal), `xray`, `sing-box`, geo data, `install-vpn.sh`, licenses |
| `xray-linux-x86_64.zip` / `xray-linux-arm64.zip` | Xray server binaries (unmodified upstream) |
| `SHA256SUMS` | Checksums the installers verify against |

## Security notes

- **Your `vless://` link is the password.** Don't share it or commit it. Real configs live only in `~/.local/xray` on your Mac and `/usr/local/etc/xray` on the server. `.gitignore` blocks them from this repo.
- **Full VPN mode** installs a LaunchDaemon that **doesn't start at boot**; it runs only when you flip the switch. It also adds a sudoers rule that lets your user start and stop **only that one daemon** without a password. The binary it runs is copied into a root-owned folder so it can't be swapped out.
- **Tunnel.app is ad-hoc signed, not notarized.** The installer clears the quarantine flag. If you download the zip by hand, right-click → Open the first time.

## Uninstall

```bash
# full VPN
sudo launchctl bootout system/local.tunnel.vpn 2>/dev/null
sudo rm -rf /Library/LaunchDaemons/local.tunnel.vpn.plist /etc/sudoers.d/tunnel-vpn /usr/local/libexec/tunnel
# proxy + app
launchctl bootout gui/$(id -u)/local.xray.client 2>/dev/null
rm -rf ~/Library/LaunchAgents/local.xray.client.plist ~/.local/xray ~/Applications/Tunnel.app
# server
sudo systemctl disable --now xray && sudo rm -rf /etc/systemd/system/xray.service /usr/local/bin/xray /usr/local/etc/xray /usr/local/share/xray
```

## Troubleshooting

- **The proxy test fails right after install:** make sure TCP 443 is open in your cloud firewall, then check `sudo systemctl status xray` on the server.
- **Full VPN is on and nothing loads:** turn it off in Tunnel.app; the proxy has to be running underneath it. The app enforces this order, but if the proxy crashed, check **XRAY LOG**.
- **Why does the full VPN go through the local proxy?** sing-box's own REALITY client wasn't compatible with Xray 26.x during testing ("reality verification failed"). So the TUN layer forwards to the local Xray SOCKS port, which handles REALITY.

## Responsible use

This is for reaching your own machines and services. Check your network's acceptable-use policy, and don't use it to break the law or anyone's terms.

## Credits & licenses

- **Tunnel** (scripts, app, docs): [MIT License](LICENSE) © 2026 Eric Hu
- **[Xray-core](https://github.com/XTLS/Xray-core)** v26.11.9, MPL-2.0: unmodified binaries redistributed in the releases
- **[sing-box](https://github.com/SagerNet/sing-box)** v1.14.4, GPL-3.0-or-later: unmodified binaries redistributed in the releases ([corresponding source](https://github.com/SagerNet/sing-box/tree/v1.14.4))

The full license texts are included in every release bundle under `licenses/`.
