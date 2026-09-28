#!/usr/bin/env bash
# Builds a signed, notarized build/Knotchy-<version>.dmg for a GitHub release.
# Needs a Developer ID Application certificate and notarization credentials saved once with
#   xcrun notarytool store-credentials knotchy --apple-id <email> --team-id <team id>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
profile="${KNOTCHY_NOTARY_PROFILE:-knotchy}"
identity="${KNOTCHY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/"Developer ID Application: / && !id { id = $2 } END { print id }')}"
if [[ -z $identity ]]; then
    echo "A release needs a Developer ID Application certificate in the keychain." >&2
    exit 1
fi
if [[ -e /Volumes/Knotchy ]]; then
    echo "Eject the mounted Knotchy disk first; Finder finds the new one by name." >&2
    exit 1
fi

notarize() {
    local result status
    result="$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json)"
    status="$(plutil -extract status raw - <<<"$result")"
    if [[ $status != Accepted ]]; then
        xcrun notarytool log "$(plutil -extract id raw - <<<"$result")" --keychain-profile "$profile" >&2 || true
        echo "Notarization of $1 failed: $status" >&2
        exit 1
    fi
}

KNOTCHY_SIGN_IDENTITY="$identity" scripts/bundle-app.sh --release
app="build/Knotchy.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"

# The app gets its own ticket so it still opens offline once it's copied out of the disk image.
ditto -c -k --keepParent "$app" build/Knotchy.zip
notarize build/Knotchy.zip
rm build/Knotchy.zip
xcrun stapler staple -q "$app"

dmg="build/Knotchy-$version.dmg"
rw="build/Knotchy-rw.dmg"
stage="build/dmg"
rm -rf "$stage" "$dmg" "$rw"
mkdir -p "$stage/.background"
ditto "$app" "$stage/Knotchy.app"
ln -s /Applications "$stage/Applications"
cp assets/dmg-background.tiff "$stage/.background/background.tiff"
hdiutil create -quiet -volname Knotchy -fs HFS+ -format UDRW -size "$(( $(du -sm "$stage" | cut -f1) + 20 ))m" \
    -srcfolder "$stage" "$rw"
rm -rf "$stage"

mnt="$(hdiutil attach -readwrite -noverify -noautoopen "$rw" | awk -F'\t' '/\/Volumes\// { print $NF }')"
trap 'hdiutil detach -quiet -force "$mnt" 2>/dev/null || true' EXIT
# Finder saves the window layout into the disk's .DS_Store; macOS asks once to let this script control Finder.
osascript - <<'EOF'
tell application "Finder"
    tell disk "Knotchy"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 840, 548}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Knotchy.app" of container window to {180, 175}
        set position of item "Applications" of container window to {460, 175}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
for _ in {1..20}; do
    [[ -f $mnt/.DS_Store ]] && break
    sleep 0.5
done
# Added after Finder is done, since laying out the window deletes the icon and clears the custom-icon flag.
cp assets/AppIcon.icns "$mnt/.VolumeIcon.icns"
xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$mnt"
rm -rf "$mnt/.fseventsd"
sync
hdiutil detach -quiet "$mnt" || { sleep 2; hdiutil detach -quiet -force "$mnt"; }
trap - EXIT
hdiutil convert -quiet "$rw" -format UDZO -imagekey zlib-level=9 -o "$dmg"
rm "$rw"
codesign --sign "$identity" --timestamp "$dmg"
notarize "$dmg"
xcrun stapler staple -q "$dmg"

spctl --assess --type open --context context:primary-signature --verbose "$dmg"
shasum -a 256 "$dmg"
