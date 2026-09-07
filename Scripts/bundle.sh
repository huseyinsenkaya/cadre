#!/bin/bash
# Cadre.app paketini kurar. Kullanım: Scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Cadre.app"
BUNDLE_ID="com.huseyinsenkaya.cadre"
VERSION="0.1.0"

cd "$ROOT"
swift build -c "$CONFIG" >&2
BIN="$(swift build -c "$CONFIG" --show-bin-path 2>/dev/null)/Cadre"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cadre"

# Simge yoksa Finder ve Dock genel bir belge simgesi gosterir.
if [ -f "$ROOT/Resources/Cadre.icns" ]; then
  cp "$ROOT/Resources/Cadre.icns" "$APP/Contents/Resources/Cadre.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Cadre</string>
  <key>CFBundleDisplayName</key><string>Cadre</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Cadre</string>
  <key>CFBundleIconFile</key><string>Cadre</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key>
  <string>Ekran kaydına kamera görüntüsünü eklemek için kamera gerekir.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Ekran kaydına sesinizi eklemek için mikrofon gerekir.</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Masaüstü simgelerini gizlemek için Finder yeniden başlatılır.</string>
</dict>
</plist>
PLIST

# İmza kimliği sabit olmalı. Ad-hoc imza her derlemede yeni bir cdhash üretir,
# macOS de uygulamayı yeni bir uygulama sayıp ekran kaydı iznini düşürür.
# İmzalı uygulamada TCC kaydı takım kimliğine bağlanır ve derlemeler arasında yaşar.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -m1 "Apple Development" \
  | sed -E 's/.*"(.*)"/\1/')"

if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -m1 "Cadre Yerel Imza" \
    | sed -E 's/.*"(.*)"/\1/')"
fi

if [ -n "$IDENTITY" ]; then
  echo "imza: $IDENTITY" >&2
  codesign --force --sign "$IDENTITY" --timestamp=none --options runtime "$APP" >&2
else
  echo "imza: ad-hoc (izin her derlemede yeniden istenir)" >&2
  codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
fi

echo "$APP"
