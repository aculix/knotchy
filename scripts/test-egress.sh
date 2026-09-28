#!/usr/bin/env bash
# Isolation regression test: from inside a VM, as the browser's user, the Mac, the
# LAN, link-local and vmnet DNS are rejected and the internet isn't; IPv6 stays shut;
# PID 1 is unprivileged. Skips fail unless KNOTCHY_EGRESS_ALLOW_SKIP=1. Bash 3.2-safe.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
name="knotchyctl-$(openssl rand -hex 4)"
work="$(mktemp -d)"
n_ok=0 n_fail=0 n_skip=0 skipped=""
http_pid="" udp_pid=""

# macOS has no timeout(1); rc 142 on timeout. The command's stderr goes via fd 3,
# so only bash's "Alarm clock" is discarded.
deadline() {
  { ( perl -e 'alarm shift; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$@" 2>&3 3>&-; exit $? ) 2>/dev/null; } 3>&2
}
cx() { deadline 20 container exec "$@"; }

cleanup() {
  trap '' INT TERM
  for pid in $http_pid $udp_pid; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  deadline 30 container stop "$name" >/dev/null 2>&1 || true
  deadline 30 container delete --force "$name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
# `container exec` swallows ^C and exits 0; don't carry on to "all checks passed".
trap 'exit 130' INT
trap 'exit 143' TERM

ok()   { printf "  ok    %s\n" "$1"; n_ok=$((n_ok + 1)); }
bad()  { printf "  FAIL  %s\n" "$1"; n_fail=$((n_fail + 1)); }
skip() { printf "  skip  %s\n" "$1"; n_skip=$((n_skip + 1)); skipped="$skipped  - $1"$'\n'; }
check() {
  if [[ "$2" == "$3" ]]; then ok "$1: $2"; else bad "$1: got '$2', want '$3'"; fi
}
summary() {
  printf "\ntest-egress: %d ok, %d fail, %d skip\n" "$n_ok" "$n_fail" "$n_skip"
  if (( n_skip )); then printf "test-egress: skipped:\n%s" "$skipped"; fi
  if (( n_skip )) && [[ "${KNOTCHY_EGRESS_ALLOW_SKIP:-}" != 1 ]]; then
    echo "test-egress: skipped checks count as failures (KNOTCHY_EGRESS_ALLOW_SKIP=1 allows them)"
    exit 1
  fi
  if (( n_fail )); then exit 1; fi
  echo "test-egress: all checks passed"
}
poll() {
  local i
  for ((i = 0; i < $1 * 2; i++)); do "${@:2}" && return 0; sleep 0.5; done
  return 1
}
# Blocked means rc 1 plus the nft reject's error: TCP/IPv4 "No route to host", TCP/IPv6
# "Permission denied", UDP "Operation not permitted". With IPv6 disabled nft never sees
# the packet: blocked-no-ipv6. Anything else (timeout, refused, exec error) fails, so a
# Mac firewall that drops SYNs can't pass for the VM's.
signature() {
  [[ "$1" == 1 && "$2" == *"$3"* ]] && why=$3
}
classify_tcp() {
  cls=inconclusive why=""
  if [[ "$1" == 0 ]]; then cls=reachable
  elif [[ "$3" != *:* ]]; then
    if signature "$1" "$2" "connect: No route to host"; then cls=blocked; fi
  elif signature "$1" "$2" "connect: Permission denied"; then cls=blocked
  elif signature "$1" "$2" "connect: Cannot assign requested address" ||
       signature "$1" "$2" "connect: Network is unreachable"; then cls=blocked-no-ipv6
  fi
}
classify_udp() {
  cls=inconclusive why=""
  if [[ "$1" == 0 ]]; then cls=reachable
  elif signature "$1" "$2" "write error: Operation not permitted"; then cls=blocked
  fi
}
verdict() {  # verdict EXPECT LABEL RC OUTPUT   (EXPECT may be "a|b")
  case "|$1|" in
    *"|$cls|"*) ok "$cls${why:+ ($why)}: $2" ;;
    *) local err; err=$(printf '%s' "$4" | tr '\n' ' ')
       bad "$cls (expected ${1//|/ or }): $2 [rc $3${err:+: ${err:0:240}}]" ;;
  esac
}
tcp() {
  local rc=0 out
  if [[ -z "$3" ]]; then skip "$2 (address unknown)"; return; fi
  out=$(cx -u knotchy "$name" timeout 3 bash -c \
    "exec 3<>/dev/tcp/$3/$4 && printf 'GET / HTTP/1.0\r\n\r\n' >&3" 2>&1) || rc=$?
  classify_tcp "$rc" "$out" "$3"
  verdict "$1" "$2" "$rc" "$out"
}
udp() {
  local rc=0 out
  if [[ -z "$3" ]]; then skip "$2 (address unknown)"; return; fi
  out=$(cx -u knotchy "$name" timeout 3 bash -c "printf x > /dev/udp/$3/$4" 2>&1) || rc=$?
  classify_udp "$rc" "$out"
  verdict "$1" "$2" "$rc" "$out"
}

# Append mode, so truncating a log doesn't leave the writer at a stale offset.
hport=$(python3 -c 'import socket; s = socket.socket(socket.AF_INET6); s.bind(("::", 0)); print(s.getsockname()[1])')
echo "MAC-REACHED" > "$work/index.html"
(cd "$work" && exec python3 -u -m http.server "$hport" --bind :: >> "$work/http.log" 2>&1) &
http_pid=$!
python3 -u -c '
import socket
s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.bind(("::", 0))
print("READY", s.getsockname()[1])
while True:
    data, addr = s.recvfrom(2048)
    print("DGRAM", addr[0], data[:64])
' >> "$work/udp.log" 2>&1 &
udp_pid=$!
http_up() { curl -fsS --noproxy '*' -o /dev/null --max-time 2 "http://127.0.0.1:$hport/" 2>/dev/null; }
udp_up() { uport=$(awk '$1 == "READY" {print $2}' "$work/udp.log"); [[ -n "$uport" ]]; }
if ! poll 10 http_up || ! poll 10 udp_up; then bad "Mac-side HTTP server / UDP listener did not start"; summary; fi

# Before the address lookups: the vmnet bridge only exists while a VM runs.
if ! out=$(KNOTCHY_FIRST_VIEWER_TIMEOUT=300 "$root/scripts/run-vm.sh" "$name" about:blank 2>&1 >/dev/null); then
  printf '%s\n' "$out"; bad "could not start $name"; summary
fi
streaming() { [[ "$(deadline 10 container logs "$name" 2>/dev/null)" == *"streaming on"* ]]; }
if ! poll 30 streaming; then bad "$name did not log 'streaming on' within 30 s"; summary; fi

gw4=$(container network inspect default | python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["status"]["ipv4Gateway"])')
bridge=""
for i in $(ifconfig -l); do
  if ifconfig "$i" | grep -F "inet $gw4 " >/dev/null; then bridge=$i; break; fi
done
# The bridge's fd… address appears ~15 s after the VM starts, tentative at first.
bridge_v6() {
  gw6=$(ifconfig "$bridge" 2>/dev/null |
    awk '$1 == "inet6" && $2 ~ /^fd/ && $0 !~ / tentative/ && !n++ {print $2}')
  [[ -n "$gw6" ]]
}
gw6=""
if [[ -n "$bridge" ]]; then poll 30 bridge_v6 || true; fi
mac4=$( (echo "$gw4"; ifconfig | awk '$1 == "inet" && $2 !~ /^127\./ {print $2}') | sort -u)
router=$(route -n get default 2>/dev/null | awk '/gateway:/ {print $2}' || true)
echo "Targets:"
echo "  Mac IPv4:$(ifconfig | awk '/^[^ \t]/ {i = substr($1, 1, length($1) - 1)}
  $1 == "inet" && $2 !~ /^127\./ {printf " %s (%s)", $2, i}')"
echo "  VM gateway $gw4 on ${bridge:-?}, bridge IPv6 ${gw6:-none}, router ${router:-none}"
echo "  HTTP port $hport, UDP port $uport"

# Otherwise "blocked" below could just mean nothing was listening.
echo "Control (from the Mac, each target must answer):"
udp_seen() { grep -F "'ctl-$1'" "$work/udp.log" >/dev/null; }
for ip in $mac4; do
  if curl -fsS --noproxy '*' -o /dev/null --max-time 3 "http://$ip:$hport/" 2>/dev/null; then
    ok "HTTP answers on $ip:$hport"
  else bad "HTTP does not answer on $ip:$hport"; fi
  { printf "ctl-%s" "$ip" > "/dev/udp/$ip/$uport"; } 2>/dev/null || true
  if poll 2 udp_seen "$ip"; then ok "UDP listener receives on $ip:$uport"
  else bad "UDP listener got nothing sent to $ip:$uport"; fi
done
if [[ -z "$gw6" ]]; then
  skip "HTTP on the bridge IPv6 (no settled fd… address on ${bridge:-the vmnet bridge} within 30 s)"
elif curl -g -fsS --noproxy '*' -o /dev/null --max-time 3 "http://[$gw6]:$hport/" 2>/dev/null; then
  ok "HTTP answers on [$gw6]:$hport"
else bad "HTTP does not answer on [$gw6]:$hport"; fi
if (( n_fail )); then echo "test-egress: control checks failed; the probes would be meaningless"; summary; fi
: > "$work/http.log"
: > "$work/udp.log"

echo "Phase A, IPv6 disabled; from inside $name as the browser user:"
for ip in $mac4; do tcp blocked "TCP Mac $ip:$hport" "$ip" "$hport"; done
tcp blocked "TCP LAN router ${router:-?}:80" "$router" 80
tcp blocked "TCP cloud metadata 169.254.169.254:80" 169.254.169.254 80
tcp reachable "TCP internet 1.1.1.1:443" 1.1.1.1 443
tcp reachable "TCP internet example.com:443" example.com 443
for ip in $mac4; do udp blocked "UDP Mac $ip:$uport" "$ip" "$uport"; done
udp blocked "UDP vmnet DNS $gw4:53" "$gw4" 53
udp blocked "UDP LAN router ${router:-?}:53" "$router" 53
udp blocked "UDP cloud metadata 169.254.169.254:53" 169.254.169.254 53
udp reachable "UDP internet DNS 1.1.1.1:53" 1.1.1.1 53
tcp "blocked|blocked-no-ipv6" "TCP Mac IPv6 [${gw6:-?}]:$hport" "$gw6" "$hport"
tcp "blocked|blocked-no-ipv6" "TCP internet IPv6 [2606:4700:4700::1111]:443" 2606:4700:4700::1111 443

echo "DNS and IPv6 state:"
check "resolv.conf nameservers" \
  "$(cx "$name" awk '$1 == "nameserver" {print $2}' /etc/resolv.conf 2>&1 | paste -sd ' ' -)" "1.1.1.1"
if cx -u knotchy "$name" getent ahostsv4 example.com >/dev/null 2>&1; then
  ok "browser user resolves example.com"
else bad "browser user cannot resolve example.com"; fi
check "all/disable_ipv6" "$(cx "$name" cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>&1)" 1

echo "Privileges of the browser process (PID 1):"
status=$(cx "$name" cat /proc/1/status 2>&1 || true)
field() { awk -v f="$1:" '$1 == f {$1 = ""; print substr($0, 2)}' <<<"$status"; }
check "Name" "$(field Name)" knotchy-agent
check "Uid (real effective saved fs)" "$(field Uid)" "1000 1000 1000 1000"
check "Gid (real effective saved fs)" "$(field Gid)" "1000 1000 1000 1000"
for c in CapInh CapPrm CapEff CapBnd CapAmb; do check "$c" "$(field $c)" 0000000000000000; done
check "NoNewPrivs" "$(field NoNewPrivs)" 1
rc=0
out=$(cx -u knotchy "$name" nft flush ruleset 2>&1) || rc=$?
if (( rc != 0 )) && [[ "$out" == *"Operation not permitted"* ]]; then
  ok "browser user cannot flush the firewall (Operation not permitted)"
else bad "nft flush ruleset as the browser user: rc $rc: $(printf '%s' "$out" | tr '\n' ' ')"; fi

# IPv6 back on so probes reach nft, and NDP let through so SLAAC can assign an address.
echo "Phase B, IPv6 re-enabled by root (proves the nft IPv6 rule):"
gw6_a=$gw6
if [[ -n "$bridge" ]]; then poll 30 bridge_v6 || true; fi
if [[ "$gw6" != "$gw6_a" ]]; then echo "  bridge IPv6 is now ${gw6:-none}"; fi
vm_v6() {  # not link-local (scope 20), not tentative (0x40)
  local addr idx plen scope flags dev
  while read -r addr idx plen scope flags dev; do
    if [[ "$dev" == eth0 && "$scope" != 20 ]] && (( (0x$flags & 0x40) == 0 )); then
      vm6=$addr; return 0
    fi
  done <<<"$(cx "$name" cat /proc/net/if_inet6 2>/dev/null || true)"
  return 1
}
vm6="" rc=0
out=$(cx "$name" sh -c '
  nft insert rule inet knotchy output icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept &&
  nft insert rule inet knotchy input icmpv6 type { nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept &&
  echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6 && echo 0 > /proc/sys/net/ipv6/conf/eth0/disable_ipv6' 2>&1) || rc=$?
if (( rc != 0 )); then
  bad "root could not open NDP and re-enable IPv6: rc $rc: $(printf '%s' "$out" | tr '\n' ' ')"
elif ! poll 15 vm_v6; then
  skip "no routable IPv6 address on eth0 within 15 s; the nft IPv6 rule is unproven"
else
  ok "eth0 has IPv6 $(sed 's/..../&:/g; s/:$//' <<<"$vm6")"
  tcp blocked "TCP Mac IPv6 [${gw6:-?}]:$hport" "$gw6" "$hport"
  tcp blocked "TCP internet IPv6 [2606:4700:4700::1111]:443" 2606:4700:4700::1111 443
  udp blocked "UDP Mac IPv6 [${gw6:-?}]:$uport" "$gw6" "$uport"
  udp blocked "UDP internet IPv6 [2606:4700:4700::1111]:53" 2606:4700:4700::1111 53
fi

echo "Mac-side evidence:"
evidence() {
  local hits
  hits=$(grep -cF "$3" "$2" || true)
  if [[ "$hits" == 0 ]]; then ok "$1 received nothing from the VM"; return; fi
  bad "$1 received $hits from the VM:"
  grep -F "$3" "$2" | sed 's/^/          /'
}
evidence "HTTP server" "$work/http.log" '"GET '
evidence "UDP listener" "$work/udp.log" 'DGRAM '

summary
