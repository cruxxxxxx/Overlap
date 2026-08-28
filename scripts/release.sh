#!/usr/bin/env bash
#
# release.sh — build, sign, notarize, and package Overlap for distribution
# outside the Mac App Store (Developer ID).
#
# One-time setup (requires an Apple Developer Program membership, $99/yr):
#   1. Xcode → Settings → Accounts → add your Apple ID → Manage Certificates
#      → + → "Developer ID Application". (Or create at developer.apple.com.)
#   2. Store notarization credentials once:
#        xcrun notarytool store-credentials overlap-notary \
#          --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
#      (generate an app-specific password at appleid.apple.com)
#   3. Set SIGN_ID below or export SIGN_ID in your shell.
#
# Then:  ./scripts/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ID="${SIGN_ID:-Developer ID Application}"   # matches your cert by prefix
NOTARY_PROFILE="${NOTARY_PROFILE:-overlap-notary}"
VERSION=$(grep -m1 MARKETING_VERSION project.yml | awk '{print $2}' | tr -d '"')
OUT="dist"
APP="$OUT/Overlap.app"
ZIP="$OUT/Overlap-$VERSION.zip"

echo "== Overlap $VERSION release =="

rm -rf "$OUT" && mkdir -p "$OUT"

echo "-- generate + build (Release) --"
xcodegen generate
xcodebuild -project Overlap.xcodeproj -scheme Overlap -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$OUT/dd" \
  CODE_SIGNING_ALLOWED=NO build | grep -E "error|BUILD" || true
cp -R "$OUT/dd/Build/Products/Release/Overlap.app" "$APP"
rm -rf "$OUT/dd"

echo "-- bundle built-in plugins --"
# overlap-suggest ships inside the app (Contents/PlugIns — PluginRegistry scans
# builtInPlugInsURL). The user Plugins dir still overrides by id, so a newer
# user-installed copy wins over the bundled one.
PLUGINS_DST="$APP/Contents/PlugIns"
mkdir -p "$PLUGINS_DST"
for name in overlap-suggest; do
    src="plugins/$name"
    exec_name=$(/usr/bin/python3 -c "import json;print(json.load(open('$src/manifest.json'))['exec'])")
    echo "   building $name"
    ( cd "$src" && swiftc -O main.swift -o "$exec_name" )
    mkdir -p "$PLUGINS_DST/$name"
    cp "$src/manifest.json" "$src/$exec_name" "$PLUGINS_DST/$name/"
    [ -f "$src/README.md" ] && cp "$src/README.md" "$PLUGINS_DST/$name/"
done

echo "-- sign (hardened runtime) --"
codesign --force --deep --options runtime --timestamp \
  --entitlements Resources/Overlap.entitlements \
  --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "-- notarize --"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "-- staple + final zip --"
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done: $ZIP  (stapled, ready to distribute)"
spctl --assess --type execute --verbose "$APP" || true
