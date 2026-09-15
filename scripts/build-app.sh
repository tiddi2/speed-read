#!/bin/bash
# Assemble sr.app from the SwiftPM release build.
# Pure-SwiftPM workflow — no Xcode project. Signing/notarization is Phase 3;
# until then the bundle is ad-hoc signed so TCC (Accessibility) grants stick.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/sr"
BUNDLE_DIR="dist/sr.app"

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"

cp "$BIN" "$BUNDLE_DIR/Contents/MacOS/sr"

# KeyboardShortcuts ships a resource bundle SwiftPM places next to the binary.
BIN_DIR="$(dirname "$BIN")"
for res in "$BIN_DIR"/*.bundle; do
  [ -e "$res" ] && cp -R "$res" "$BUNDLE_DIR/Contents/Resources/"
done

# Kokoro daemon script — installed into App Support by the in-app installer.
cp daemon/sr_tts_server.py "$BUNDLE_DIR/Contents/Resources/"
cp daemon/requirements.lock "$BUNDLE_DIR/Contents/Resources/kokoro-requirements.lock"

# App icon (Dock, Finder, ⌘-Tab, About). Regenerate with scripts/make-icon.py.
cp resources/sr.icns "$BUNDLE_DIR/Contents/Resources/sr.icns"

cat > "$BUNDLE_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>sr</string>
    <key>CFBundleDisplayName</key>       <string>sr</string>
    <key>CFBundleIdentifier</key>        <string>com.patrickellis.sr</string>
    <key>CFBundleExecutable</key>        <string>sr</string>
    <key>CFBundleIconFile</key>          <string>sr</string>
    <key>CFBundleIconName</key>          <string>sr</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>© 2026 Patrick Ellis. MIT License.</string>
</dict>
</plist>
PLIST

# Sign with the local "sr-dev" certificate when present: unlike ad-hoc
# signing (whose identity is the per-build binary hash), a real certificate
# gives a stable designated requirement, so the Accessibility grant survives
# rebuilds. Falls back to ad-hoc if the cert is missing (grant re-prompts
# after every rebuild in that case). Phase 3 replaces this with Developer ID.
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"sr-dev"'; then
  codesign --force --deep --sign "sr-dev" "$BUNDLE_DIR"
else
  echo "warning: sr-dev cert not found — ad-hoc signing (TCC grants won't survive rebuilds)" >&2
  codesign --force --deep --sign - "$BUNDLE_DIR"
fi

echo "Built $BUNDLE_DIR"
