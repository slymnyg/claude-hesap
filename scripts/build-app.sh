#!/bin/zsh
# Universal (arm64 + x86_64) "Claude Hesap.app" paketini dist/ altına derler.
# Kullanım: scripts/build-app.sh [sürüm]   (varsayılan: VERSION dosyası)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(cat VERSION)}"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/ClaudeHesap"

APP="dist/Claude Hesap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeHesap"
for f in AppIcon.icns menubar.png menubar@2x.png; do
  if [[ -f "Assets/$f" ]]; then cp "Assets/$f" "$APP/Contents/Resources/"; fi
done
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Claude Hesap</string>
  <key>CFBundleDisplayName</key><string>Claude Hesap</string>
  <key>CFBundleIdentifier</key><string>com.suleymanyag.claude-hesap</string>
  <key>CFBundleExecutable</key><string>ClaudeHesap</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>tr</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Derlendi: $APP ($VERSION)"
