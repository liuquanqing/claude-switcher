#!/bin/bash
# Stop only this application's user agent; retain all profile and session data.
set -euo pipefail
APP="${1:-/Applications/Claude Switcher.app}"
"$APP/Contents/MacOS/ClaudeSwitcher" --stop-protection
echo 'Protection has stopped. You may now move the application to Trash. Account data was retained.'
