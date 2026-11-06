#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p _qa/rc7/visual
python3 - <<'INNER'
from pathlib import Path
s=Path('App/main.swift').read_text()
Path('_qa/rc7/visual/AppDeclarations.swift').write_text(s[:s.index('if CommandLine.arguments.contains("--stop-protection")')])
protection_view = Path('App/ProtectionView.swift').read_text()
initial_state = '@State private var showSettings = false'
assert protection_view.count(initial_state) == 1
Path('_qa/rc7/visual/FixtureProtectionView.swift').write_text(protection_view.replace(initial_state,
    '@State private var showSettings = CommandLine.arguments.contains("--fixture-protection-expanded")'))
protection_model = Path('App/Protection.swift').read_text()
demo_time = 'guardCheckedAt = Date()'
assert protection_model.count(demo_time) == 1
protection_model = protection_model.replace(demo_time,
    'guardCheckedAt = Date().addingTimeInterval(CommandLine.arguments.contains("--fixture-diagnostic-disagrees") ? -12 : 0)')
manager_input = 'Bundle.main.object(forInfoDictionaryKey: "CSPreviewAPIManager") as? String'
assert protection_model.count(manager_input) == 1
Path('_qa/rc7/visual/FixtureProtection.swift').write_text(protection_model.replace(manager_input,
    '(CommandLine.arguments.first(where: { $0.hasPrefix("--fixture-api-source=") })?.components(separatedBy: "=").last ?? (' + manager_input + '))'))
INNER
app_sources=()
for file in App/*.swift; do
 if [[ "$file" != "App/main.swift" && "$file" != "App/Protection.swift" && "$file" != "App/ProtectionView.swift" ]]; then app_sources+=("$file"); fi
done
app_sources+=(_qa/rc7/visual/FixtureProtection.swift _qa/rc7/visual/FixtureProtectionView.swift)
swiftc -module-cache-path _qa/rc7/visual/module-cache -target "$(uname -m)-apple-macos13.0" -parse-as-library -I _qa/controller-check/model-module -L _qa/controller-check/model-module -lSwitcherCore -Xlinker -rpath -Xlinker "$PWD/_qa/controller-check/model-module" "${app_sources[@]}" _qa/rc7/visual/AppDeclarations.swift scripts/fixtures/unified-controls-render.swift -framework SwiftUI -framework AppKit -framework Security -framework ServiceManagement -o _qa/rc7/visual/render > _qa/rc7/visual/render-build.log 2>&1
python3 - <<'INNER'
from pathlib import Path
import plistlib, shutil
contents = Path('_qa/rc7/visual/ClaudeSwitcherUIFixture.app/Contents')
(contents / 'MacOS').mkdir(parents=True, exist_ok=True)
(contents / 'Resources').mkdir(exist_ok=True)
shutil.copy2('_qa/rc7/visual/render', contents / 'MacOS/Renderer')
shutil.copyfile('assets/icon-candidates/switcher-flow-v6.png', contents / 'Resources/AppIcon.png')
(contents / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'dev.claudeswitcher.ui-fixture', 'CFBundleExecutable': 'Renderer',
    'CFBundleName': 'Claude Switcher UI Fixture', 'CFBundlePackageType': 'APPL',
    'CSPreviewMode': True, 'LSUIElement': True}))
INNER
_qa/rc7/visual/ClaudeSwitcherUIFixture.app/Contents/MacOS/Renderer --demo > _qa/rc7/visual/render.log 2>&1
