#!/usr/bin/env bash
# --dns: the vmnet DNS forwarder isn't reachable on every network.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
container build --cpus 4 --memory 4g --dns 1.1.1.1 --pull \
  --build-arg WERROR=-Werror \
  --build-arg APT_REFRESH="$(date -u +%Y-%m-%d)" \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -f "$root/vm/Containerfile" -t local/knotchy-vm:latest "$root/vm"
