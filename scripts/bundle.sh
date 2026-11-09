#!/bin/zsh
# Builds DBMan.app (release) into ./dist. Usage: scripts/bundle.sh [debug]
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-release}
swift build -c "$config"
bindir=$(swift build -c "$config" --show-bin-path)
bin=$bindir/DBMan
app=dist/DBMan.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
cp "$bin" "$app/Contents/MacOS/DBMan"
cp "$bindir/dbman-mcp" "$app/Contents/Helpers/dbman-mcp" # the stdio shim agents launch (SPEC §1.1)
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns" # built by scripts/icon.sh
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DBMan</string>
  <key>CFBundleDisplayName</key><string>DBMan</string>
  <key>CFBundleIdentifier</key><string>com.dbman.app</string>
  <key>CFBundleExecutable</key><string>DBMan</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.8.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>SQLite database</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>CFBundleTypeExtensions</key><array><string>sqlite</string><string>sqlite3</string><string>db</string></array>
  </dict></array>
</dict></plist>
PLIST
# SIGN_IDENTITY set (make install): real signature + hardened runtime, so Keychain "Always Allow" survives reinstalls.
# Unset: ad-hoc signature for local dev builds.
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$app/Contents/Helpers/dbman-mcp" # inside-out: helper first
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$app"
else
  codesign --force --sign - "$app/Contents/Helpers/dbman-mcp" >/dev/null
  codesign --force --sign - "$app" >/dev/null
fi
echo "$app"
