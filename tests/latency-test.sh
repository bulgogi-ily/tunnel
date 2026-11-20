#!/bin/bash
# latency-test.sh — compare round-trip latency: no tunnel vs. proxy vs. full VPN.
#
#   bash tests/latency-test.sh            # direct + proxy (+ full VPN if installed)
#
# ICMP ping is often blocked on filtered networks, so this measures the round trip of
# requests 2..11 on one kept-alive HTTPS connection (no handshake) and reports the median.
# If full-VPN mode is installed it is switched on only for its own test and always switched
# off again at the end.
TARGETS="LosAngeles|https://lax-ca-us-ping.vultr.com/vultr.com.100MB.bin
NewYork|https://nj-us-ping.vultr.com/vultr.com.100MB.bin
Texas|https://tx-us-ping.vultr.com/vultr.com.100MB.bin
Montreal|https://bhs.proof.ovh.ca/
Toronto|https://tor-ca-ping.vultr.com/vultr.com.100MB.bin"

rtt() {
  local u=$1; shift; local a=()
  for i in $(seq 11); do a+=(-o /dev/null "$u"); done
  curl -sk --max-time 25 -r 0-0 "$@" -w '%{time_starttransfer} %{num_connects}\n' "${a[@]}" 2>/dev/null \
    | awk '$2==0 && $1>0 {print $1*1000}' | sort -n \
    | awk '{v[NR]=$1} END{ if(NR==0) print "FAIL"; else printf "%4.0f ms (min %.0f)", v[int((NR+1)/2)], v[1] }'
}
run() {
  local label=$1; shift; echo "## $label"
  while IFS='|' read -r name url; do printf '  %-11s %s\n' "$name" "$(rtt "$url" "$@")"; done <<< "$TARGETS"
}

VPN_PLIST=/Library/LaunchDaemons/local.tunnel.vpn.plist
vpn_off() { sudo -n /bin/launchctl bootout system/local.tunnel.vpn 2>/dev/null || true; }

[ -f "$VPN_PLIST" ] && { trap vpn_off EXIT; vpn_off; sleep 1; }
run "NO TUNNEL" --noproxy '*'
if nc -z -G 2 127.0.0.1 10808 2>/dev/null; then run "PROXY (socks5 127.0.0.1:10808)" --socks5-hostname 127.0.0.1:10808
else echo "## PROXY: not running, skipped"; fi
if [ -f "$VPN_PLIST" ]; then
  sudo -n /bin/launchctl bootstrap system "$VPN_PLIST" && sleep 3
  echo "## FULL VPN (exit IP $(curl -s --max-time 8 --noproxy '*' https://api.ipify.org))"
  run "FULL VPN" --noproxy '*'
else echo "## FULL VPN: not installed, skipped"; fi
