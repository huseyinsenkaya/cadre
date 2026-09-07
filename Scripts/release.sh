#!/bin/bash
# Cadre'i dagitima hazirlar: imzala, noter onayina gonder, bileti ekle, DMG uret.
#
# Onkosullar:
#   1. Ucretli Apple Developer uyeligi
#   2. Anahtarlikta "Developer ID Application" sertifikasi
#   3. Noter kimligi:
#      xcrun notarytool store-credentials "cadre" \
#        --apple-id <e-posta> --team-id <takim-kimligi> --password <uygulama-parolasi>
#
# Kullanim: Scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Cadre.app"
DIST="$ROOT/dist"
PROFILE="cadre"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0")"
DMG="$DIST/Cadre-$VERSION.dmg"

IDENTITY="$(security find-identity -v -p codesigning \
  | grep -m1 "Developer ID Application" \
  | sed -E 's/.*"(.*)"/\1/')"

if [ -z "$IDENTITY" ]; then
  echo "HATA: Developer ID Application sertifikasi yok." >&2
  echo "developer.apple.com/account uzerinden uret ve anahtarliga ekle." >&2
  exit 1
fi

echo "1/6 Uygulama derleniyor"
"$ROOT/Scripts/bundle.sh" release >/dev/null

echo "2/6 Dagitim kimligiyle imzalaniyor: $IDENTITY"
# Sertlestirilmis calisma zamani noter onayinin sartidir.
codesign --force --deep --options runtime --timestamp \
  --entitlements "$ROOT/Scripts/entitlements.plist" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "3/6 Noter onayina gonderiliyor"
mkdir -p "$DIST"
ZIP="$DIST/Cadre-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "4/6 Bilet uygulamaya ekleniyor"
# Bilet olmadan internet baglantisi olmayan makinede Gatekeeper uygulamayi durdurur.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "5/6 DMG uretiliyor"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Cadre" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "6/6 DMG imzalaniyor ve dogrulaniyor"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo
echo "Hazir: $DMG"
echo "Boyut: $(du -h "$DMG" | cut -f1)"
echo "Bu dosyayi siteye koy. Indiren kisi cift tiklar ve uyari almaz."
