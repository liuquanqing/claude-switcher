#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p _qa/rc7/visual
python3 - <<'INNER'
from pathlib import Path
s=Path('App/main.swift').read_text()
Path('_qa/rc7/visual/AppDeclarations.swift').write_text(s[:s.index('if CommandLine.arguments.contains("--stop-protection")')])
INNER
app_sources=()
for file in App/*.swift; do
 if [[ "$file" != "App/main.swift" ]]; then app_sources+=("$file"); fi
done
swiftc -module-cache-path _qa/rc7/visual/module-cache -target "$(uname -m)-apple-macos13.0" -parse-as-library -I _qa/controller-check/model-module -L _qa/controller-check/model-module -lSwitcherCore -Xlinker -rpath -Xlinker "$PWD/_qa/controller-check/model-module" "${app_sources[@]}" _qa/rc7/visual/AppDeclarations.swift scripts/fixtures/unified-controls-render.swift -framework SwiftUI -framework AppKit -framework Security -framework ServiceManagement -o _qa/rc7/visual/render > _qa/rc7/visual/render-build.log 2>&1
_qa/rc7/visual/render --demo > _qa/rc7/visual/render.log 2>&1
