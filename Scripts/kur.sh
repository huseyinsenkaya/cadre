#!/bin/bash
# Cadre'i /Applications altina kurar. Kullanim: Scripts/kur.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/Cadre.app"

pkill -x Cadre 2>/dev/null || true
APP="$("$ROOT/Scripts/bundle.sh" release)"

rm -rf "$DEST"
cp -R "$APP" "$DEST"

# Finder simgeyi paket tarihine gore onbellekler. Dokunmazsan eski simge kalir.
touch "$DEST"

open "$DEST"
echo "Kuruldu: $DEST"
echo "Oturum acilisinda baslasin: Cadre → Settings → General → Open Cadre at login"
