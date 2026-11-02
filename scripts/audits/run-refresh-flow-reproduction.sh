#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD/_qa/refresh-flow-reproduction"
mkdir -p "$root/module" "$root/compiler-cache"
python3 - "$root/AppDeclarations.swift" <<'PY'
from pathlib import Path
import sys
source=Path('App/main.swift').read_text()
Path(sys.argv[1]).write_text(source[:source.index('if CommandLine.arguments.contains("--stop-protection")')])
PY
app_sources=()
for source in App/*.swift; do
  if [[ "$source" != "App/main.swift" ]]; then app_sources+=("$source"); fi
done
swiftc -module-cache-path "$root/compiler-cache" -target "$(uname -m)-apple-macos13.0" -emit-library -emit-module -module-name SwitcherCore Sources/SwitcherCore/*.swift -o "$root/module/libSwitcherCore.dylib"
swiftc -module-cache-path "$root/compiler-cache" -target "$(uname -m)-apple-macos13.0" -parse-as-library -I "$root/module" -L "$root/module" -lSwitcherCore -Xlinker -rpath -Xlinker "$root/module" "${app_sources[@]}" "$root/AppDeclarations.swift" scripts/audits/refresh-flow-reproduction.swift -framework SwiftUI -framework AppKit -framework Security -framework ServiceManagement -o "$root/audit"
"$root/audit" > "$root/reproduction.json"
cat "$root/reproduction.json"
