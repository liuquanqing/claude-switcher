#!/bin/bash
# Build is local only. Installation and guard registration are explicit actions.
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-build}"
case "$MODE" in build|install|dmg|test) ;; *) echo 'Usage: ./build.sh [build|install|dmg|test]' >&2; exit 2 ;; esac
if [ "$MODE" = test ]; then exec swift test; fi
swift build -c release --product ClaudeSwitcher
swift build -c release --product ClaudeGuard
swift build -c release --product ClaudeSessionTransfer
BIN="$(swift build -c release --show-bin-path)"
APP="$PWD/build/Claude Switcher.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
bash scripts/build-icon.sh
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp assets/icon-candidates/switcher-flow-v6.png "$APP/Contents/Resources/AppIcon.png"
cp "$BIN/ClaudeSwitcher" "$APP/Contents/MacOS/ClaudeSwitcher"
cp "$BIN/ClaudeGuard" "$APP/Contents/Helpers/ClaudeGuard"
cp "$BIN/ClaudeSessionTransfer" "$APP/Contents/Helpers/ClaudeSessionTransfer"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Claude Switcher 候选版</string>
<key>CFBundleIdentifier</key><string>dev.claudeswitcher.candidate</string>
<key>CFBundleExecutable</key><string>ClaudeSwitcher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.3.0-local.6</string>
<key>CFBundleVersion</key><string>20261029.6.7</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP/Contents/Helpers/ClaudeGuard"
codesign --force -s - "$APP/Contents/Helpers/ClaudeSessionTransfer"
codesign --force -s - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
if [ "$MODE" = install ]; then
  TARGET='/Applications/Claude Switcher 候选版.app'
  if pgrep -f '^/Applications/Claude Switcher 候选版.app/Contents/MacOS/ClaudeSwitcher' >/dev/null; then
    echo 'Quit the existing switcher before installing. No application was stopped.' >&2
    exit 1
  fi
  if pgrep -f '^/Applications/Claude.app/Contents/MacOS/Claude' >/dev/null; then
    echo 'Quit Claude before replacing its guard component. No application was stopped.' >&2
    exit 1
  fi
  BACKUPS="$HOME/Library/Application Support/ClaudeSwitcher/install-backups"
  mkdir -p "$BACKUPS"
  if [ -e "$TARGET" ]; then
    BACKUP="$BACKUPS/Claude Switcher-$(date -u +%Y%m%dT%H%M%SZ).app"
    [ ! -e "$BACKUP" ] || { echo 'Backup already exists; refusing overwrite.' >&2; exit 1; }
    mv "$TARGET" "$BACKUP"
  fi
  if ! ditto "$APP" "$TARGET"; then
    # Preserve any incomplete copy for inspection before restoring the prior app.
    [ ! -e "$TARGET" ] || mv "$TARGET" "$BACKUPS/incomplete-$(date -u +%Y%m%dT%H%M%SZ).app"
    [ -z "${BACKUP:-}" ] || mv "$BACKUP" "$TARGET"
    exit 1
  fi
  GUIDE='docs/INSTALL.md'
  [ -f "$GUIDE" ] || GUIDE='docs/安装与迁移.md'
  echo "Installed candidate. No login item or guard was registered. Read $GUIDE before enabling protection."
fi
if [ "$MODE" = dmg ]; then
  exec scripts/package-release.sh --skip-build
fi
