# SysMon

Красивый монитор системы для macOS в menu bar: CPU, память, сеть, диск. Glassmorphism-дашборд с живыми графиками.

![SysMon](https://img.shields.io/badge/macOS-12+-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![Universal](https://img.shields.io/badge/Universal-arm64%20%2B%20x86__64-green)

## Возможности

- Иконка в menu bar с живыми CPU / RAM / ↑скорость сети
- Дашборд (⌘D) — кольца загрузки, история CPU/RAM, графики сети, индикаторы ядер
- Автозапуск при входе в систему (LaunchAgent)
- Универсальный бинарник: Apple Silicon + Intel
- Нативный AppKit + WKWebView, без зависимостей
- Размер ~90 КБ

## Сборка

```bash
./build.sh
```

Соберёт `build/SysMon.app` и `build/SysMon-installer.zip` (дистрибутив для других Mac).

Требуется только Xcode Command Line Tools (`xcode-select --install`).

## Запуск

```bash
open build/SysMon.app
```

Или скопировать в `/Applications/`.

## Установка на другой Mac

Передайте `build/SysMon-installer.zip`. На целевом Mac:

```bash
unzip SysMon-installer.zip
bash install.sh
```

Установщик копирует в `/Applications`, снимает карантин Gatekeeper, переподписывает ad-hoc, спрашивает про автозапуск.

## Структура

```
sysmon/
├── src/
│   ├── main.swift      # AppKit + Mach API: статистика, NSStatusItem, WKWebView
│   ├── index.html      # дашборд (HTML + JS + SVG-графики)
│   ├── Info.plist      # bundle metadata, LSUIElement=true (без иконки в Dock)
│   ├── install.sh      # установщик для других Mac
│   └── README.txt      # инструкция для пользователя дистрибутива
└── build.sh            # сборка универсального бинарника + zip
```

## Технологии

- **Swift / AppKit** — нативное приложение macOS, menu bar через `NSStatusItem`
- **Mach API** — `host_processor_info`, `host_statistics64` для CPU и памяти
- **getifaddrs** — счётчики сетевого трафика по интерфейсам
- **WKWebView** — окно дашборда (HTML/CSS/JS, SVG-графики)
- **LaunchAgent** — автозапуск через `~/Library/LaunchAgents`
- **codesign --sign -** — ad-hoc подпись для распространения без Apple Developer ID

## Лицензия

MIT
