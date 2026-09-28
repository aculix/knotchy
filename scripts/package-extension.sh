#!/usr/bin/env bash
# Zips extensions/chrome for the Chrome Web Store: build/open-in-knotchy-<version>.zip.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/extensions/chrome"
version="$(plutil -extract version raw manifest.json)"
out="$root/build/open-in-knotchy-$version.zip"
mkdir -p "$root/build"
rm -f "$out"
zip -q -r -X "$out" manifest.json background.js icons -x '*.DS_Store'
echo "$out"
