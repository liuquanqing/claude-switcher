#!/bin/bash
# Build and package a separately named candidate. Never installs or controls a service.
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  "") ./build.sh ;;
  --skip-build) ;;
  *) echo "Usage: scripts/package-release.sh [--skip-build]" >&2; exit 2 ;;
esac
ARCH="$(uname -m)"
SOURCE="$PWD/build/Claude Switcher.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SOURCE/Contents/Info.plist")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Claude Switcher 候选版.app"
ditto --norsrc --noextattr "$SOURCE" "$APP"
python3 - "$APP" <<'PY'
from pathlib import Path
import plistlib, sys
p = Path(sys.argv[1]) / 'Contents/Info.plist'
v = plistlib.loads(p.read_bytes())
assert not any(k.startswith('CSPreview') for k in v)
v.update(CFBundleIdentifier='dev.claudeswitcher.candidate', CFBundleName='Claude Switcher 候选版', CFBundleDisplayName='Claude Switcher 候选版')
p.write_bytes(plistlib.dumps(v))
PY
# Remove local debug paths from distributed executables, then sign the changed helpers.
for binary in "$APP/Contents/MacOS/ClaudeSwitcher" "$APP/Contents/Helpers/ClaudeGuard" "$APP/Contents/Helpers/ClaudeSessionTransfer"; do
  strip -S "$binary"
done
codesign --force -s - "$APP/Contents/Helpers/ClaudeGuard"
codesign --force -s - "$APP/Contents/Helpers/ClaudeSessionTransfer"
codesign --force -s - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p dist
ZIP="$PWD/dist/ClaudeSwitcher-$VERSION-$ARCH.zip"
DMG="$PWD/dist/ClaudeSwitcher-$VERSION-$ARCH.dmg"
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$ZIP"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Claude Switcher $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
python3 - "$ZIP" "$DMG" <<'PY'
from pathlib import Path
import hashlib, json, plistlib, subprocess, sys
files = [Path(x) for x in sys.argv[1:]]
root = Path.cwd()
info = plistlib.loads((root / 'build/Claude Switcher.app/Contents/Info.plist').read_bytes())
sums = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(root / 'dist/SHA256SUMS').write_text(''.join(f'{digest}  {name}\n' for name, digest in sums.items()))
manifest = {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'], 'architecture': subprocess.check_output(['uname', '-m'], text=True).strip(), 'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(), 'bundleIdentifier': 'dev.claudeswitcher.candidate', 'appName': 'Claude Switcher 候选版.app', 'signing': 'ad-hoc; not notarized', 'files': sums}
(root / 'dist/RELEASE-MANIFEST.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
PY
printf 'Packages and checksums written to dist/\n'
