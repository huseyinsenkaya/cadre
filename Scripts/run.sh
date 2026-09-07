#!/bin/bash
# Cadre'i yeniden kurar ve başlatır.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
pkill -x Cadre 2>/dev/null || true
APP="$("$ROOT/Scripts/bundle.sh" "${1:-debug}")"
open "$APP"
echo "Cadre çalışıyor: $APP"
