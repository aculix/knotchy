#!/usr/bin/env bash
# scripts/run-vm.sh NAME URL: starts a VM with the app's flags, prints the host socket.
# Env: KNOTCHY_DEBUG, KNOTCHY_FIRST_VIEWER_TIMEOUT, KNOTCHY_ENV_FILE, KNOTCHY_SECRETS_DIR.
# Name VMs knotchyctl-<8 hex> so the app's orphan sweep ignores them.
set -euo pipefail
name="${1:?usage: run-vm.sh NAME URL}"
url="${2:?usage: run-vm.sh NAME URL}"
if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]]; then
  echo "run-vm.sh: invalid VM name '$name' (lowercase letters, digits, dashes)" >&2; exit 2
fi
if [[ "$name" =~ ^knotchy-[0-9a-f]{8}$ ]]; then
  echo "run-vm.sh: '$name' uses the app's naming; use knotchyctl-<8 hex>" >&2; exit 2
fi

tmp="${TMPDIR:-/tmp}"
run_dir="${tmp%/}/knotchy"
mkdir -p -m 700 "$run_dir"
if [[ ! -d "$run_dir" || -L "$run_dir" || ! -O "$run_dir" ]]; then
  echo "run-vm.sh: refusing unsafe socket directory $run_dir" >&2; exit 1
fi
chmod 700 "$run_dir"
sock="$run_dir/$name.sock"
rm -f "$sock"

# The Mac's networks may be public addresses, so the VM blocks them explicitly.
block=$(python3 - <<'PY'
import ipaddress, re, subprocess
out = subprocess.run(["ifconfig"], capture_output=True, text=True).stdout
nets = set()
for ip, mask in re.findall(r"inet (\d+\.\d+\.\d+\.\d+)(?: --> \S+)? netmask 0x([0-9a-f]{8})", out):
    if ip.startswith("127."):
        continue
    net = ipaddress.ip_network(f"{ip}/{bin(int(mask, 16)).count('1')}", strict=False)
    if net.prefixlen >= 8:
        nets.add(str(net))
print(" ".join(sorted(nets)))
PY
)
if [[ -z "$block" ]]; then
  echo "run-vm.sh: warning: found no Mac IPv4 networks to block" >&2
fi

container run -d --rm --name "$name" \
  --cpus 4 --memory 2g --shm-size 512m \
  --dns 1.1.1.1 \
  --cap-add NET_ADMIN \
  --masked-path NONE --read-only-path NONE \
  --publish-socket "$sock:/tmp/knotchy/knotchy.sock" \
  -e "KNOTCHY_URL=$url" \
  -e "KNOTCHY_SIZE=1024x640" \
  -e "KNOTCHY_BLOCK_CIDRS=$block" \
  -e "KNOTCHY_DEBUG=${KNOTCHY_DEBUG:-0}" \
  -e "KNOTCHY_FIRST_VIEWER_TIMEOUT=${KNOTCHY_FIRST_VIEWER_TIMEOUT:-60}" \
  ${KNOTCHY_ENV_FILE:+--env-file "$KNOTCHY_ENV_FILE"} \
  ${KNOTCHY_SECRETS_DIR:+--cap-add SYS_ADMIN --mount "type=bind,source=$KNOTCHY_SECRETS_DIR,target=/run/knotchy-secrets"} \
  local/knotchy-vm:latest >/dev/null
echo "$sock"
