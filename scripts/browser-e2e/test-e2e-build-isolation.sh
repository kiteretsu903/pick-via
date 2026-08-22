#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
normal_app="$repo_root/build/PickVia.app"
e2e_app="$repo_root/build-e2e/PickVia E2E.app"
normal_executable="$normal_app/Contents/MacOS/PickVia"
e2e_executable="$e2e_app/Contents/MacOS/PickVia"
marker="PICKVIA_E2E_AUTOMATION_ENABLED"
environment_keys=(
  PICKVIA_E2E_TARGET_ID
  PICKVIA_E2E_BUNDLE_ID
  PICKVIA_E2E_MODE
  PICKVIA_E2E_SESSION_NONCE
  PICKVIA_E2E_SUPPORT_DIR
  PICKVIA_E2E_STATUS_FIFO
)

binary_contains() {
  local binary="$1"
  local needle="$2"
  grep -Fq "$needle" < <(strings "$binary")
}

zsh "$repo_root/scripts/build-app.sh" >/dev/null
zsh "$repo_root/scripts/build-e2e-app.sh" >/dev/null

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$normal_app/Contents/Info.plist")" = \
  "dev.bozhenpeng.PickVia"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$e2e_app/Contents/Info.plist")" = \
  "dev.bozhenpeng.PickVia.E2E"

! binary_contains "$normal_executable" "$marker"
binary_contains "$e2e_executable" "$marker"

for key in "${environment_keys[@]}"; do
  ! binary_contains "$normal_executable" "$key"
  binary_contains "$e2e_executable" "$key"
done
