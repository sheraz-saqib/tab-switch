#!/bin/bash
# ./build.sh           -> build/TabSwitch.app
# ./build.sh install   -> also copy to /Applications and launch
# ./build.sh release   -> also build/TabSwitch-<version>.zip + .sha256
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.0.0}"

swift build -c release

# .icns from the 1024px source (redraw it with: swift scripts/make-icon.swift Resources/icon-1024.png)
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

APP=build/TabSwitch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TabSwitch "$APP/Contents/MacOS/"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sheraz.tabswitch</string>
  <key>CFBundleName</key><string>TabSwitch</string>
  <key>CFBundleExecutable</key><string>TabSwitch</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Stable local identity if present (easy-finder/scripts/make-cert.sh creates it): macOS then keeps the
# Accessibility / Screen Recording grants across rebuilds. Otherwise ad-hoc. Set SIGN_ID for a real Developer ID.
if [[ -z "${SIGN_ID:-}" ]] && security find-certificate -c "Easy Finder Dev" >/dev/null 2>&1; then SIGN_ID="Easy Finder Dev"; fi
codesign --force --options runtime --timestamp=none --sign "${SIGN_ID:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION)"

case "${1:-}" in
  install)
    # An ad-hoc signature changes every build, so old grants go stale (toggle shows ON but doesn't apply).
    # Reset them so macOS asks fresh on launch.
    if [[ -z "${SIGN_ID:-}" ]]; then
      tccutil reset Accessibility com.sheraz.tabswitch >/dev/null 2>&1 || true
      tccutil reset ScreenCapture com.sheraz.tabswitch >/dev/null 2>&1 || true
    fi
    pkill -x TabSwitch || true
    rm -rf /Applications/TabSwitch.app
    cp -R "$APP" /Applications/
    open /Applications/TabSwitch.app ;;
  release)
    ZIP="build/TabSwitch-${VERSION}.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    (cd build && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
    cat "$ZIP.sha256" ;;
esac
