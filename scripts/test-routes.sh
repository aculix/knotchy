#!/usr/bin/env bash
# Proxy and VPN route test (vm/knotchy-init): each route lets out only what it should,
# secrets stay out of the environment and `container inspect`, and pages load through
# knotchyctl. Bash 3.2-safe. Needs local/knotchy-vm:latest and the fixture:
#   container build --dns 1.1.1.1 -t local/knotchy-route-server scripts/route-server
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
server="knotchyctl-$(openssl rand -hex 4)"
vm=""
work="$(mktemp -d)"
n_ok=0 n_fail=0

deadline() {
  { ( perl -e 'alarm shift; exec @ARGV or die "exec $ARGV[0]: $!\n"' "$@" 2>&3 3>&-; exit $? ) 2>/dev/null; } 3>&2
}
cleanup() {
  trap '' INT TERM
  for name in $vm $server; do
    deadline 30 container stop "$name" >/dev/null 2>&1 || true
    deadline 30 container delete --force "$name" >/dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ok()  { printf "  ok    %s\n" "$1"; n_ok=$((n_ok + 1)); }
bad() { printf "  FAIL  %s\n" "$1"; n_fail=$((n_fail + 1)); }
summary() {
  printf "\ntest-routes: %d ok, %d fail\n" "$n_ok" "$n_fail"
  if (( n_fail )); then exit 1; fi
  echo "test-routes: all checks passed"
}
poll() {
  local i
  for ((i = 0; i < $1 * 2; i++)); do "${@:2}" && return 0; sleep 0.5; done
  return 1
}

# probe USER VM tcp|udp HOST PORT -> "reachable", "blocked" (the nft reject),
# "unreachable" (no route) or "other: …"
probe() {
  local rc=0 out cmd
  if [[ "$3" == tcp ]]; then cmd="exec 3<>/dev/tcp/$4/$5 && printf 'GET / HTTP/1.0\r\n\r\n' >&3"
  else cmd="printf x > /dev/udp/$4/$5"; fi
  out=$(deadline 20 container exec -u "$1" "$2" timeout 3 bash -c "$cmd" 2>&1) || rc=$?
  if [[ $rc == 0 ]]; then echo reachable
  elif [[ $rc == 1 && ( "$out" == *"No route to host"* || "$out" == *"Operation not permitted"* ) ]]; then echo blocked
  elif [[ $rc == 1 && "$out" == *"Network is unreachable"* ]]; then echo unreachable
  else echo "other: rc $rc $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"; fi
}
expect() {  # expect "WANT|WANT2" LABEL USER tcp|udp HOST PORT
  local got
  got=$(probe "$3" "$vm" "$4" "$5" "$6")
  case "|$1|" in *"|$got|"*) ok "$got: $2" ;; *) bad "$got (expected ${1//|/ or }): $2" ;; esac
}

start_vm() {
  vm="knotchyctl-$(openssl rand -hex 4)"
  if ! KNOTCHY_ENV_FILE="$1" KNOTCHY_SECRETS_DIR="${2:-}" KNOTCHY_FIRST_VIEWER_TIMEOUT=300 \
      "$root/scripts/run-vm.sh" "$vm" about:blank >/dev/null; then
    bad "could not start $vm"; summary
  fi
  streaming() { [[ "$(deadline 10 container logs "$vm" 2>/dev/null)" == *"streaming on"* ]]; }
  if ! poll 30 streaming; then
    bad "$vm did not start streaming"; deadline 10 container logs "$vm" 2>&1 | tail -5; summary
  fi
}
stop_vm() {
  deadline 30 container stop "$vm" >/dev/null 2>&1 || true
  deadline 30 container delete --force "$vm" >/dev/null 2>&1 || true
  vm=""
}

if ! deadline 60 container run -d --rm --name "$server" --dns 1.1.1.1 --cap-add NET_ADMIN \
    --masked-path NONE --read-only-path NONE local/knotchy-route-server:latest >/dev/null; then
  bad "could not start the route server (build it: see the top of this script)"; summary
fi
ready() { [[ "$(deadline 10 container logs "$server" 2>/dev/null)" == *"route-server ready"* ]]; }
if ! poll 30 ready; then bad "route server did not come up"; summary; fi
srv=$(deadline 10 container logs "$server" | awk '/route-server ready/ {print $NF}')
gw4=$(container network inspect default | python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["status"]["ipv4Gateway"])')
echo "Route server $srv, Mac (vmnet gateway) $gw4"

echo "Proxy route (HTTP proxy $srv:8888):"
printf 'KNOTCHY_ROUTE=proxy\nKNOTCHY_PROXY_ADDR=%s:8888\n' "$srv" > "$work/proxy.env"
mkdir -m 700 "$work/secrets"
printf 'KNOTCHY_PROXY_URL=http://knotchy:s3cr3t@%s:8888\n' "$srv" > "$work/secrets/route"
start_vm "$work/proxy.env" "$work/secrets"
if [[ ! -e "$work/secrets/route" ]]; then ok "the VM deleted the secrets file"; else bad "the secrets file is still on the Mac"; fi
if ! deadline 10 container exec "$vm" grep -q knotchy-secrets /proc/mounts; then ok "the secrets share is unmounted"
else bad "the secrets share is still mounted"; fi
if ! deadline 10 container inspect "$vm" | grep -q s3cr3t; then ok "container inspect doesn't show the password"
else bad "container inspect shows the password"; fi
capbnd=$(deadline 10 container exec "$vm" awk '/^CapBnd/ {print $2}' /proc/1/status)
if [[ "$capbnd" == 0000000000000000 ]]; then ok "the browser has no capabilities (SYS_ADMIN dropped)"; else bad "CapBnd $capbnd"; fi
expect reachable "the proxy port" knotchy tcp "$srv" 8888
expect blocked "the fixture's other port" knotchy tcp "$srv" 1080
expect blocked "the internet directly (1.1.1.1:443)" knotchy tcp 1.1.1.1 443
expect blocked "DNS directly (1.1.1.1:53)" knotchy udp 1.1.1.1 53
expect blocked "the Mac" knotchy tcp "$gw4" 22
environ=$(deadline 10 container exec -u knotchy "$vm" cat /proc/1/environ | tr '\0' '\n')
if [[ "$environ" == *"https_proxy=http://knotchy:s3cr3t@$srv:8888"* && "$environ" != *KNOTCHY_PROXY* ]]; then
  ok "the browser gets https_proxy and none of the KNOTCHY_PROXY_* variables"
else bad "the browser's environment is wrong"; fi
stop_vm

echo "WireGuard route (server $srv:51820):"
client=$(deadline 10 container exec "$server" cat /tmp/client.conf)
key=$(awk '$1 == "PrivateKey" {print $3}' <<< "$client")
pub=$(awk '$1 == "PublicKey" {print $3}' <<< "$client")
setconf=$(printf '[Interface]\nPrivateKey = %s\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:51820\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' "$key" "$pub" "$srv" | base64 | tr -d '\n')
# A private resolver on the VPN side, as Mullvad and Proton VPN use.
printf 'KNOTCHY_ROUTE=wireguard\nKNOTCHY_WG_SETCONF=%s\nKNOTCHY_WG_ENDPOINT=%s:51820\nKNOTCHY_WG_ADDRESS=10.99.0.2/32\nKNOTCHY_WG_DNS=10.99.0.1\nKNOTCHY_WG_MTU=1420\n' \
  "$setconf" "$srv" > "$work/wg.env"
start_vm "$work/wg.env"
route=$(deadline 10 container exec "$vm" ip -4 route get 1.1.1.1)
if [[ "$route" == *"dev wg0"* ]]; then ok "the internet routes through wg0"; else bad "the internet routes: $route"; fi
before=$(deadline 10 container exec "$server" wg show wg0 transfer | awk '{print $2}')
expect reachable "the internet through the tunnel (1.1.1.1:443)" knotchy tcp 1.1.1.1 443
after=$(deadline 10 container exec "$server" wg show wg0 transfer | awk '{print $2}')
if [[ -n "$after" && "${after:-0}" -gt "${before:-0}" ]]; then ok "the server saw the traffic ($before -> $after bytes)"
else bad "the server's received bytes didn't grow ($before -> $after)"; fi
expect blocked "the server's other port, outside the tunnel" knotchy tcp "$srv" 8888
expect blocked "the endpoint, for the browser's user" knotchy udp "$srv" 51820
expect blocked "the Mac" knotchy tcp "$gw4" 22
expect blocked "a private address on the VPN side (10.99.0.2 -> 10.99.0.1:22)" knotchy tcp 10.99.0.1 22
expect reachable "DNS to the VPN's resolver (10.99.0.1:53)" knotchy udp 10.99.0.1 53
expect blocked "another port on the VPN's resolver (10.99.0.1:80)" knotchy tcp 10.99.0.1 80
resolv=$(deadline 10 container exec "$vm" cat /etc/resolv.conf)
if [[ "$resolv" == "nameserver 10.99.0.1" ]]; then ok "resolv.conf names the VPN's DNS only"; else bad "resolv.conf: $resolv"; fi
environ=$(deadline 10 container exec -u knotchy "$vm" cat /proc/1/environ | tr '\0' '\n')
if [[ "$environ" != *KNOTCHY_WG* ]]; then ok "the browser doesn't get the WireGuard keys"; else bad "KNOTCHY_WG_* reached the browser"; fi
deadline 10 container exec "$vm" pkill wireguard-go || true
sleep 1
expect "blocked|unreachable" "the internet with the tunnel gone" knotchy tcp 1.1.1.1 443
via=$(deadline 10 container exec "$vm" ip -4 route get "$srv" | awk '{for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1)}')
deadline 10 container exec "$vm" ip -4 route replace default via "${via:-$gw4}" dev eth0 || true
expect blocked "the internet over a restored direct route" knotchy tcp 1.1.1.1 443
stop_vm

echo "Missing route settings:"
for route in proxy wireguard; do
  printf 'KNOTCHY_ROUTE=%s\n' "$route" > "$work/broken.env"
  rc=0
  out=$(deadline 60 container run --rm --dns 1.1.1.1 --cap-add NET_ADMIN --masked-path NONE --read-only-path NONE \
    --env-file "$work/broken.env" -e KNOTCHY_URL=about:blank local/knotchy-vm:latest 2>&1) || rc=$?
  if [[ $rc != 0 && "$out" == *"knotchy-init: "* && "$out" != *"streaming on"* ]]; then
    ok "a $route route without its settings stops the VM ($(grep -o 'knotchy-init: .*' <<< "$out" | head -1))"
  else bad "a $route route without its settings didn't stop the VM (rc $rc)"; fi
done

# The app refuses a proxy on the local network without --allow-local-proxy.
echo "End to end (knotchyctl):"
swift build --package-path "$root" --product knotchyctl >/dev/null
ctl="$(swift build --package-path "$root" --product knotchyctl --show-bin-path)/knotchyctl"
snap() {
  if deadline 120 "$ctl" snapshot https://example.com "$2" --after 2 "${@:3}" >/dev/null 2>"$work/ctl.err"; then return 0; fi
  bad "$1: knotchyctl failed: $(tail -1 "$work/ctl.err")"; return 1
}
if snap "HTTP proxy" "$work/http.png" --allow-local-proxy --proxy "http://knotchy:s3cr3t@$srv:8888"; then
  if deadline 10 container exec "$server" grep -q 'Established connection to host "example.com"' /tmp/tinyproxy.log; then
    ok "a page loads through the HTTP proxy"
  else bad "the HTTP proxy didn't carry the page"; fi
fi
if snap "SOCKS5 proxy" "$work/socks.png" --allow-local-proxy --proxy "socks5://knotchy:s3cr3t@$srv:1080"; then
  if deadline 10 container exec "$server" grep -q 'connected to example.com:443' /tmp/microsocks.log; then
    ok "a page loads through the SOCKS5 proxy"
  else bad "the SOCKS5 proxy didn't carry the page"; fi
fi
deadline 10 container exec "$server" sh -c ': > /tmp/tinyproxy.log'
if snap "wrong password" "$work/wrong.png" --allow-local-proxy --proxy "http://knotchy:wrong@$srv:8888"; then
  if deadline 10 container exec "$server" grep -q 'Established connection' /tmp/tinyproxy.log; then
    bad "a wrong proxy password still got through"
  else ok "a wrong proxy password gets nowhere"; fi
fi
if ! deadline 120 "$ctl" snapshot https://example.com "$work/local.png" --proxy "http://knotchy:s3cr3t@$srv:8888" \
    >/dev/null 2>"$work/ctl.err" && grep -q "use a proxy on this Mac or your local network" "$work/ctl.err"; then
  ok "a proxy on the local network is refused"
else bad "a proxy on the local network wasn't refused: $(tail -1 "$work/ctl.err")"; fi
deadline 10 container exec "$server" cat /tmp/client.conf > "$work/client.conf"
before=$(deadline 10 container exec "$server" wg show wg0 transfer | awk '{print $2}')
if snap "WireGuard" "$work/wg.png" --wireguard "$work/client.conf"; then
  after=$(deadline 10 container exec "$server" wg show wg0 transfer | awk '{print $2}')
  if [[ "${after:-0}" -gt $(( ${before:-0} + 2000 )) ]]; then ok "a page loads through the WireGuard tunnel"
  else bad "the tunnel didn't carry the page ($before -> $after bytes)"; fi
fi
summary
