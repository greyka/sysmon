#!/bin/bash
# Установщик SysMon. Положите этот файл рядом с SysMon.app и запустите его.
set -e

cd "$(dirname "$0")"
APP="SysMon.app"

if [ ! -d "$APP" ]; then
  echo "✗ Не найден $APP рядом с install.sh"
  exit 1
fi

DEST="/Applications/$APP"

echo "▸ Копирование в /Applications"
if [ -d "$DEST" ]; then
  # если уже установлено — попробуем тихо остановить
  pkill -f "/Applications/SysMon.app/Contents/MacOS/SysMon" 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST"
fi
cp -R "$APP" /Applications/

echo "▸ Снятие карантина Gatekeeper"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "▸ Ad-hoc подпись (на этой машине)"
codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true

read -p "▸ Включить автозапуск при входе? [y/N] " yn
case "$yn" in
  [Yy]*)
    PLIST="$HOME/Library/LaunchAgents/com.sysmon.menubar.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.sysmon.menubar</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$DEST</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "  ✓ Автозапуск включён"
    ;;
  *) echo "  (автозапуск можно включить позже в меню приложения)";;
esac

echo "▸ Запуск"
open "$DEST"

echo
echo "✓ Готово. Иконка появится в строке меню (сверху справа)."
echo "  Если macOS всё-таки ругается «нельзя открыть»:"
echo "    Системные настройки → Конфиденциальность и безопасность → нажать «Открыть всё равно»."
