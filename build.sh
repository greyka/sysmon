#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="SysMon"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="dist"

echo "▸ Очистка"
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST_DIR"

ARM_BIN="$BUILD_DIR/SysMon-arm64"
X86_BIN="$BUILD_DIR/SysMon-x86_64"

echo "▸ Компиляция arm64"
swiftc -O -target arm64-apple-macos12.0 \
  -framework Cocoa -framework WebKit -framework ServiceManagement \
  -o "$ARM_BIN" src/main.swift

echo "▸ Компиляция x86_64"
if swiftc -O -target x86_64-apple-macos12.0 \
     -framework Cocoa -framework WebKit -framework ServiceManagement \
     -o "$X86_BIN" src/main.swift 2>/dev/null; then
  echo "▸ Создание универсального бинарника (lipo)"
  lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/$APP_NAME"
else
  echo "  (x86_64 SDK недоступен — собираем только arm64)"
  cp "$ARM_BIN" "$APP/Contents/MacOS/$APP_NAME"
fi
chmod +x "$APP/Contents/MacOS/$APP_NAME"

echo "▸ Сборка ресурсов"
cp src/Info.plist "$APP/Contents/Info.plist"
cp src/index.html "$APP/Contents/Resources/index.html"

echo "▸ Подпись (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "▸ Создание установщика"
cp src/install.sh "$DIST_DIR/install.sh"
cp src/README.txt "$DIST_DIR/README.txt"
chmod +x "$DIST_DIR/install.sh"
cp -R "$APP" "$DIST_DIR/"

echo "▸ Упаковка zip"
( cd "$DIST_DIR" && zip -qr "../$BUILD_DIR/SysMon-installer.zip" . )

echo
echo "✓ Готово."
file "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/  /'
echo
echo "  Локальный запуск:   open \"$PWD/$APP\""
echo "  Дистрибутив:        $PWD/$BUILD_DIR/SysMon-installer.zip"
echo "  Папка установщика:  $PWD/$DIST_DIR/"
