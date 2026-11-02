#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Historical reproduction must not crash or claim to validate fixed candidates.
python3 - <<'HISTORICAL'
from pathlib import Path
import subprocess,sys
baseline='d6cb36ffc14e994a1ac6a3b89fe0773bac0fb02f'
for name in ['App/AutomaticAccountRefresh.swift','App/CurrentCLIRecoveryController.swift','Sources/SwitcherCore/UsageRefreshPolicy.swift']:
    original=subprocess.check_output(['git','show',baseline+':'+name])
    if Path(name).read_bytes()!=original:
        print('HISTORICAL_REPRODUCTION_ONLY: candidate changed; run scripts/test-controller.sh for current regressions.')
        sys.exit(2)
HISTORICAL
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
