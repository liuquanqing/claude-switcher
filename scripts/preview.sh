#!/bin/bash
# Build a separately identified, fake-data-only bundle. Does not launch it.
set -euo pipefail
cd "$(dirname "$0")/.."
MANY=0
BLOCKED=0
for option in "$@"; do
  case "$option" in --many) MANY=1 ;; --blocked) BLOCKED=1 ;; *) echo 'Usage: scripts/preview.sh [--many] [--blocked]' >&2; exit 2 ;; esac
done
SOURCE="$PWD/build/Claude Switcher.app"
[ -x "$SOURCE/Contents/MacOS/ClaudeSwitcher" ] || { echo 'Run ./build.sh first.' >&2; exit 1; }
NAME='Claude Switcher Preview'
SUFFIX='preview'
if [ "$MANY" = 1 ]; then NAME="$NAME Many"; SUFFIX="$SUFFIX.many"; fi
if [ "$BLOCKED" = 1 ]; then NAME="$NAME Blocked"; SUFFIX="$SUFFIX.blocked"; fi
TARGET="$PWD/_qa/$NAME.app"
mkdir -p "$PWD/_qa"
if [ -e "$TARGET" ]; then
  echo 'Preview bundle already exists. Quit and remove only that generated preview before rebuilding it.' >&2
  exit 1
fi
ditto "$SOURCE" "$TARGET"
python3 - "$TARGET/Contents/Info.plist" "$NAME" "$SUFFIX" "$MANY" "$BLOCKED" <<'PY'
from pathlib import Path
import plistlib,sys
p=Path(sys.argv[1]);d=plistlib.loads(p.read_bytes())
d.update(CFBundleIdentifier='dev.claudeswitcher.'+sys.argv[3],CFBundleName=sys.argv[2],
         CSPreviewMode=True,CSPreviewManyAccounts=sys.argv[4]=='1',CSPreviewBlocked=sys.argv[5]=='1')
p.write_bytes(plistlib.dumps(d))
PY
codesign --force -s - "$TARGET"
echo "$TARGET"
