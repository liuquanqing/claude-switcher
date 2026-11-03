#!/bin/bash
# Fictional AppKit windows only. No account, credential, proxy or service access.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p _qa/popover-check
swiftc -parse-as-library -module-cache-path _qa/popover-check/module-cache \
  App/PopoverDismissalController.swift scripts/fixtures/popover-dismissal-checks.swift \
  -framework AppKit -o _qa/popover-check/popover-check
_qa/popover-check/popover-check
