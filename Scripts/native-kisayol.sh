#!/bin/bash
# macOS'un ⌘⇧4 ekran goruntusu kisayolunu kapatir ya da geri acar.
# Kullanim: Scripts/native-kisayol.sh kapat | ac
set -euo pipefail

# 30 = "Save picture of selected area as a file" (⌘⇧4)
ID=30
ACTION="${1:-kapat}"

case "$ACTION" in
  kapat) ENABLED=false ;;
  ac)    ENABLED=true ;;
  *) echo "Kullanim: $0 kapat | ac"; exit 1 ;;
esac

defaults write com.apple.symbolichotkeys AppleSymbolicHotKeys -dict-add "$ID" "
<dict>
  <key>enabled</key><$ENABLED/>
  <key>value</key><dict>
    <key>parameters</key><array>
      <integer>52</integer><integer>21</integer><integer>1179648</integer>
    </array>
    <key>type</key><string>standard</string>
  </dict>
</dict>"

/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings -u

echo "macOS ⌘⇧4 kisayolu: $ACTION"
echo "Cadre'i yeniden baslat: pkill -x Cadre; open -a Cadre"
