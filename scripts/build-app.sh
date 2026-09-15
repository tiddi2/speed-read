#!/bin/bash
# Assemble sr.app from the SwiftPM release build.
# Pure-SwiftPM workflow — no Xcode project. Distribution signing/notarization is
# Phase 3; until then the bundle is signed with the local "sr-dev" identity that
# scripts/setup-signing.sh maintains, which is what makes the Accessibility grant
# and the Keychain ACL survive a rebuild.
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
  [ -e "$res" ] || continue
  cp -R "$res" "$BUNDLE_DIR/Contents/Resources/"
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

# Sign with the local "sr-dev" identity. An ad-hoc signature's identity is the
# binary's own hash, so it changes with every build and macOS forgets both the
# Accessibility grant and the Keychain ACL each time; a certificate gives a
# designated requirement that stays put. setup-signing.sh creates the identity
# on first build and is a no-op afterwards — set SR_SKIP_SIGNING_SETUP=1 to
# build without it (ad-hoc, grants reset on every rebuild).
SIGN_IDENTITY=""
SIGN_KEYCHAIN=""
if [ "${SR_SKIP_SIGNING_SETUP:-0}" != "1" ]; then
  if signing_env="$(bash scripts/setup-signing.sh --print-env)"; then
    eval "$signing_env"
    SIGN_IDENTITY="${SR_SIGN_IDENTITY:-}"
    SIGN_KEYCHAIN="${SR_SIGN_KEYCHAIN:-}"
  fi
fi

if [ -z "$SIGN_IDENTITY" ]; then
  echo "warning: no sr-dev identity — ad-hoc signing (Accessibility and Keychain" >&2
  echo "         grants will reset on every rebuild). Fix: make setup-signing" >&2
fi

# --timestamp=none keeps the build offline; a local certificate cannot be
# timestamped by Apple's service anyway.
sign() {
  local target="$1"; shift
  if [ -n "$SIGN_IDENTITY" ]; then
    local keychain_arg=()
    [ -n "$SIGN_KEYCHAIN" ] && keychain_arg=(--keychain "$SIGN_KEYCHAIN")
    codesign --force --timestamp=none \
      ${keychain_arg[@]+"${keychain_arg[@]}"} --sign "$SIGN_IDENTITY" "$@" "$target"
  else
    codesign --force --timestamp=none --sign - "$@" "$target"
  fi
}

# Inside out rather than --deep, which is deprecated and re-signs nested code
# with the outer bundle's options.
for res in "$BUNDLE_DIR"/Contents/Resources/*.bundle; do
  [ -e "$res" ] || continue
  sign "$res"
done
sign "$BUNDLE_DIR" --identifier "com.patrickellis.sr"
codesign --verify --strict "$BUNDLE_DIR"

# The designated requirement is the identity TCC and the Keychain remember. It
# is worth seeing: if it changes between builds, the grants are about to reset.
DR="$(codesign -d -r- "$BUNDLE_DIR" 2>/dev/null | sed -n 's/^designated => //p')"

echo "Built $BUNDLE_DIR"
echo "  identity: ${SIGN_IDENTITY:-ad-hoc}"
echo "  designated requirement: ${DR:-unknown}"
