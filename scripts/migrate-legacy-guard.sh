#!/bin/bash
# Explicit migration only. Never run during development or while Claude is active.
set -euo pipefail
case "${1:-}" in
  '') DRY_RUN=0 ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo 'Usage: migrate-legacy-guard.sh [--dry-run]' >&2; exit 2 ;;
esac
desktop_is_running() {
  /bin/ps -axww -o comm= | /usr/bin/awk '/\/Contents\/MacOS\/Claude$/ { found = 1 } END { exit !found }'
}
if desktop_is_running; then
  if [ "$DRY_RUN" = 1 ]; then
    echo 'Dry run: Claude is active; a real migration would refuse to proceed. No service changed.'
    exit 0
  fi
  echo 'Quit Claude before migrating. No service was changed.' >&2
  exit 1
fi
BACKUP="/Library/Application Support/claude-switcher-migration-$(date -u +%Y%m%dT%H%M%SZ)"
if [ "$DRY_RUN" = 1 ]; then
  echo 'Dry run: would unload local.claude-bodyguard and local.tz-watchdog and back up their plist files.'
  echo "Backup would be: $BACKUP"
  echo 'No service, account data or system settings changed.'
  exit 0
fi
sudo /bin/bash -s -- "$BACKUP" <<'ROOT'
set -euo pipefail
backup="$1"
# The admin authorization prompt may take time; recheck before changing any job.
if /bin/ps -axww -o comm= | /usr/bin/awk '/\/Contents\/MacOS\/Claude$/ { found = 1 } END { exit !found }'; then
  echo 'Claude was reopened during preparation. No service changed.' >&2
  exit 1
fi
[ ! -e "$backup" ] || { echo 'Backup already exists.' >&2; exit 1; }
install -d -o root -g wheel -m 700 "$backup"
for label in local.claude-bodyguard local.tz-watchdog; do
  if launchctl print "system/$label" >/dev/null 2>&1; then launchctl bootout "system/$label"; fi
  plist="/Library/LaunchDaemons/$label.plist"
  if [ -e "$plist" ]; then mv "$plist" "$backup/"; fi
done
# Keep the old script directory in place as recovery material; no accounts are touched.
echo 'Legacy jobs unloaded and their plist files backed up. No system settings were restored or changed.'
ROOT
echo 'Migration complete. Enable protection in Claude Switcher before reopening Claude.'
