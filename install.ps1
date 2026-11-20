# Tunnel — one-command Windows installer (no admin needed for the proxy).
#
#   powershell -ExecutionPolicy Bypass -c "& ([scriptblock]::Create((irm https://raw.githubusercontent.com/bulgogi-ily/tunnel/main/install.ps1))) 'vless://...'"
#
# Installs Xray (proxy) + sing-box (full VPN) from this repo's GitHub Release into
# %LOCALAPPDATA%\Tunnel, starts the proxy at login, and adds desktop shortcuts:
#   Tunnel ON        - start proxy + set Windows system proxy (browsers, most apps)
#   Tunnel FULL VPN  - route EVERY app incl. games (asks for admin once per start)
#   Tunnel OFF       - stop everything and restore normal internet
param([string]$Link = $env:TUNNEL_LINK)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'bulgogi-ily/tunnel'
$Rel  = "https://github.com/$Repo/releases/latest/download"
$Dest = Join-Path $env:LOCALAPPDATA 'Tunnel'
function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# ---------- 1. parse the vless:// link ----------
if (-not $Link) { $Link = Read-Host 'Paste your vless:// link' }
$Link = $Link.Trim()
if ($Link -notmatch '^vless://([^@]+)@([^:/?#]+):(\d+)\?([^#]*)') { Die "That doesn't look like a vless:// link." }
$Uuid = $Matches[1]; $Server = $Matches[2]; $Port = [int]$Matches[3]; $Query = $Matches[4]
$Q = @{}
foreach ($kv in $Query.Split('&')) { $p = $kv.Split('=', 2); if ($p.Count -eq 2) { $Q[$p[0]] = [Uri]::UnescapeDataString($p[1]) } }
$Pub = $Q['pbk']; $Sid = $Q['sid']; $Sni = $Q['sni']
if (-not ($Pub -and $Sid -and $Sni)) { Die 'Link is missing pbk/sid/sni.' }
Say "Server ${Server}:$Port (camouflage: $Sni)"

# ---------- 2. download + verify ----------
$Tmp = Join-Path $env:TEMP ("tunnel-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Tmp | Out-Null
Say 'Downloading tunnel-windows-x64.zip'
Invoke-WebRequest "$Rel/tunnel-windows-x64.zip" -OutFile "$Tmp\bundle.zip" -UseBasicParsing
Invoke-WebRequest "$Rel/SHA256SUMS" -OutFile "$Tmp\SHA256SUMS" -UseBasicParsing
$want = (Get-Content "$Tmp\SHA256SUMS" | Where-Object { $_ -match ' tunnel-windows-x64\.zip$' }) -replace '\s.*$', ''
$got = (Get-FileHash "$Tmp\bundle.zip" -Algorithm SHA256).Hash.ToLower()
if (-not $want -or $want -ne $got) { Die 'Checksum mismatch - download corrupted or tampered with.' }
Say 'Checksum OK'

# stop any previous copy before overwriting
Get-Process xray, sing-box -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$Dest*" } | Stop-Process -Force -ErrorAction SilentlyContinue
Expand-Archive "$Tmp\bundle.zip" -DestinationPath $Tmp -Force
New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Copy-Item "$Tmp\tunnel-windows-x64\*" $Dest -Recurse -Force
Remove-Item $Tmp -Recurse -Force
Get-ChildItem $Dest -Recurse | Unblock-File

# ---------- 3. configs ----------
$xray = @"
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {"tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": true}},
    {"tag": "http",  "listen": "127.0.0.1", "port": 10809, "protocol": "http"}
  ],
  "outbounds": [{
    "tag": "proxy", "protocol": "vless",
    "settings": {"vnext": [{"address": "$Server", "port": $Port,
      "users": [{"id": "$Uuid", "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
    "streamSettings": {
      "network": "tcp", "security": "reality",
      "sockopt": {"tcpFastOpen": true, "tcpNoDelay": true},
      "realitySettings": {"serverName": "$Sni", "fingerprint": "chrome", "publicKey": "$Pub", "shortId": "$Sid"}
    }
  }]
}
"@
$ipRule = ''
if ($Server -match '^\d+\.\d+\.\d+\.\d+$') { $ipRule = "{`"ip_cidr`": [`"$Server/32`"], `"outbound`": `"direct`"}," }
$tun = @"
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
    {"type": "tun", "tag": "tun-in", "interface_name": "Tunnel", "address": ["172.19.0.1/30"], "mtu": 1500,
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
      $ipRule
      {"process_name": ["xray.exe"], "outbound": "direct"},
      {"action": "sniff"},
      {"protocol": "dns", "action": "hijack-dns"},
      {"ip_is_private": true, "outbound": "direct"}
    ],
    "final": "proxy"
  }
}
"@
$utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM (Go JSON parsers dislike it)
[IO.File]::WriteAllText("$Dest\config.json", $xray, $utf8)
[IO.File]::WriteAllText("$Dest\tun.json", $tun, $utf8)
& "$Dest\xray.exe" run -test -config "$Dest\config.json" | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'Xray rejected the config.' }
& "$Dest\sing-box.exe" check -c "$Dest\tun.json"
if ($LASTEXITCODE -ne 0) { Die 'sing-box rejected the VPN config.' }

# ---------- 4. control script ----------
$ctl = @'
param([ValidateSet('on','off','vpn','autostart')][string]$Cmd = 'on')
$D = Split-Path -Parent $MyInvocation.MyCommand.Path
$IS = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Add-Type -Namespace W -Name I -MemberDefinition '[DllImport("wininet.dll")] public static extern bool InternetSetOption(System.IntPtr h, int o, System.IntPtr b, int l);' -ErrorAction SilentlyContinue
function Refresh { [W.I]::InternetSetOption(0, 39, 0, 0) | Out-Null; [W.I]::InternetSetOption(0, 37, 0, 0) | Out-Null }
function ProxyOn {
  if (-not (Get-Process xray -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$D*" })) {
    Start-Process "$D\xray.exe" -ArgumentList 'run','-config',"$D\config.json" -WorkingDirectory $D -WindowStyle Hidden
    Start-Sleep -Milliseconds 800
  }
}
function SysProxy([bool]$on) {
  Set-ItemProperty $IS ProxyEnable ([int]$on)
  if ($on) { Set-ItemProperty $IS ProxyServer '127.0.0.1:10809'; Set-ItemProperty $IS ProxyOverride '<local>;localhost;127.*;10.*;172.16.*;192.168.*' }
  Refresh
}
function Notify($m) { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show($m, 'Tunnel') | Out-Null }
switch ($Cmd) {
  'autostart' { ProxyOn }
  'on'  { ProxyOn; SysProxy $true; Notify 'Tunnel ON - browsers and most apps now go through the tunnel.' }
  'vpn' {
    ProxyOn; SysProxy $false
    Start-Process "$D\sing-box.exe" -ArgumentList 'run','-c',"$D\tun.json" -WorkingDirectory $D -WindowStyle Hidden -Verb RunAs
    Notify 'FULL VPN ON - every app (games too) now goes through the tunnel. Use "Tunnel OFF" to stop.'
  }
  'off' {
    SysProxy $false
    if (Get-Process sing-box -ErrorAction SilentlyContinue) {
      Start-Process taskkill -ArgumentList '/F','/IM','sing-box.exe' -Verb RunAs -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
    }
    Get-Process xray -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$D*" } | Stop-Process -Force
    Notify 'Tunnel OFF - normal internet restored.'
  }
}
'@
[IO.File]::WriteAllText("$Dest\tunnel.ps1", $ctl, $utf8)

# ---------- 5. shortcuts + autostart ----------
$sh = New-Object -ComObject WScript.Shell
function Lnk($path, $cmd, $desc) {
  $l = $sh.CreateShortcut($path)
  $l.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  $l.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dest\tunnel.ps1`" $cmd"
  $l.WorkingDirectory = $Dest; $l.Description = $desc
  $l.IconLocation = "$env:WINDIR\System32\shell32.dll,$(if ($cmd -eq 'off') {131} else {13})"
  $l.Save()
}
$desk = [Environment]::GetFolderPath('Desktop')
Lnk "$desk\Tunnel ON.lnk" on 'Proxy on (browsers, most apps)'
Lnk "$desk\Tunnel FULL VPN.lnk" vpn 'Every app incl. games (admin prompt)'
Lnk "$desk\Tunnel OFF.lnk" off 'Stop the tunnel'
Lnk "$([Environment]::GetFolderPath('Startup'))\Tunnel (background).lnk" autostart 'Start tunnel proxy at login'

# ---------- 6. start + test ----------
Say 'Starting and testing...'
& powershell -NoProfile -ExecutionPolicy Bypass -File "$Dest\tunnel.ps1" autostart
Start-Sleep -Seconds 2
try {
  $ip = (Invoke-WebRequest 'https://api.ipify.org' -Proxy 'http://127.0.0.1:10809' -UseBasicParsing -TimeoutSec 10).Content
  Say "Tunnel works - traffic exits at $ip"
} catch {
  Write-Host "Tunnel test failed: check the server is running and TCP $Port is open in its firewall." -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Done! Use the desktop shortcuts:' -ForegroundColor Green
Write-Host '  Tunnel ON        - browsers and most apps'
Write-Host '  Tunnel FULL VPN  - everything incl. games (click Yes on the admin prompt)'
Write-Host '  Tunnel OFF       - back to normal internet'
