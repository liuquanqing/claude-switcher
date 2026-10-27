#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p _qa/controller-check
python3 - <<'INNER'
from pathlib import Path
s=Path('App/main.swift').read_text()
i=s.index('if CommandLine.arguments.contains("--stop-protection")')
Path('_qa/controller-check/AppDeclarations.swift').write_text('// Test compilation: exact declaration prefix, excluding application entrypoint.\n'+s[:i])
INNER
mkdir -p _qa/controller-check/model-module
swiftc -target "$(uname -m)-apple-macos13.0" -emit-library -emit-module -module-name SwitcherCore Sources/SwitcherCore/*.swift -o _qa/controller-check/model-module/libSwitcherCore.dylib
swiftc -target "$(uname -m)-apple-macos13.0" -parse-as-library -I _qa/controller-check/model-module -L _qa/controller-check/model-module -lSwitcherCore -Xlinker -rpath -Xlinker "$PWD/_qa/controller-check/model-module" $(rg --files App -g '*.swift' | rg -v '^App/main.swift$') _qa/controller-check/AppDeclarations.swift scripts/fixtures/controller-check.swift -framework SwiftUI -framework AppKit -framework Security -framework ServiceManagement -o _qa/controller-check/controller-check
_qa/controller-check/controller-check
