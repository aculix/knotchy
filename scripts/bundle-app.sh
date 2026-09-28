#!/usr/bin/env bash
# Builds Knotchy.app, installs it to ~/Applications and refreshes the Services menu.
# Signs with the keychain's Developer ID certificate (or KNOTCHY_SIGN_IDENTITY), ad hoc if there is none.
# --release skips the install and adds the secure timestamp notarization needs; see scripts/release.sh.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

release=0
[[ ${1:-} == --release ]] && release=1
identity="${KNOTCHY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Developer ID Application: / && !id { id = $2 } END { print id }')}"
if (( release )) && [[ -z $identity ]]; then
    echo "A release needs a Developer ID Application certificate in the keychain." >&2
    exit 1
fi

swift build -c release --product Knotchy
bin="$(swift build -c release --product Knotchy --show-bin-path)/Knotchy"

app="$root/build/Knotchy.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/Knotchy"
cp Sources/Knotchy/Info.plist "$app/Contents/Info.plist"
cp assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# The image is built from these on the user's Mac.
cp -R vm "$app/Contents/Resources/vm"
find "$app" -name .DS_Store -delete

if [[ -z $identity ]]; then
    codesign --force --sign - "$app"
elif (( release )); then
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
else
    codesign --force --options runtime --timestamp=none --sign "$identity" "$app"
fi
if (( release )); then
    exit 0
fi

dest="$HOME/Applications/Knotchy.app"
mkdir -p "$HOME/Applications"
pkill -x Knotchy 2>/dev/null || true
rm -rf "$dest"
cp -R "$app" "$dest"
/System/Library/CoreServices/pbs -update
echo "Installed $dest"
