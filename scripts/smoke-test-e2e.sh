#!/bin/zsh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
policy="$repo_root/scripts/browser-e2e/smoke_e2e_runtime.py"
requested_app="${1:-$repo_root/build-e2e/PickVia E2E.app}"
app=""
helper_source="$repo_root/scripts/browser-e2e/open_with_app.swift"
marker="PICKVIA_E2E_AUTOMATION_ENABLED"
session_nonce="smoke_session_0123456789"
environment_keys=(
  PICKVIA_E2E_TARGET_ID
  PICKVIA_E2E_BUNDLE_ID
  PICKVIA_E2E_MODE
  PICKVIA_E2E_SESSION_NONCE
  PICKVIA_E2E_SUPPORT_DIR
  PICKVIA_E2E_STATUS_FIFO
)

fail() {
  print -u2 -r -- "$1"
  exit 1
}

policy_command() {
  /usr/bin/env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=en_US.UTF-8 \
    LC_CTYPE=UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    /usr/bin/python3 "$policy" "$@"
}

app="$(policy_command canonical-app "$requested_app")" || \
  fail "E2E smoke app path is invalid"
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/PickVia"
resources="$app/Contents/Resources"
app_identity="$(policy_command app-identity "$app")" || \
  fail "E2E smoke app identity is invalid"

binary_contains() {
  local binary="$1"
  local needle="$2"
  /usr/bin/grep -Fq "$needle" < <(/usr/bin/strings "$binary")
}

test -x "$executable"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = \
  "dev.bozhenpeng.PickVia.E2E"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist")" = "PickVia E2E"
test "$(/usr/libexec/PlistBuddy -c 'Print :PickViaE2EAutomation' "$plist")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :PickViaE2EAutomationMarker' "$plist")" = "$marker"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" = "14.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist")" = "true"

test "$(/usr/bin/plutil -extract CFBundleURLTypes raw -o - "$plist")" -eq 2
test "$(/usr/bin/plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes raw -o - "$plist")" -eq 2
scheme0="$(/usr/bin/plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$plist")"
scheme1="$(/usr/bin/plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.1 raw -o - "$plist")"
test "$scheme0:$scheme1" = "http:https" || test "$scheme0:$scheme1" = "https:http"
test "$(/usr/bin/plutil -extract CFBundleURLTypes.1.CFBundleURLSchemes raw -o - "$plist")" -eq 1
test "$(/usr/bin/plutil -extract CFBundleURLTypes.1.CFBundleURLSchemes.0 raw -o - "$plist")" = \
  "mailto"

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" = "PickVia"
test -s "$resources/PickVia.icns"
test -s "$resources/PickViaMenuBarTemplate.png"
test "$(/usr/bin/sips -g pixelWidth "$resources/PickViaMenuBarTemplate.png" | /usr/bin/awk '/pixelWidth/ {print $2}')" = \
  "44"
test "$(/usr/bin/sips -g pixelHeight "$resources/PickViaMenuBarTemplate.png" | /usr/bin/awk '/pixelHeight/ {print $2}')" = \
  "44"

expected_resources=$'PickVia.icns\nPickViaMenuBarTemplate.png'
actual_resources="$(/usr/bin/find "$resources" -mindepth 1 -maxdepth 1 -type f -exec /usr/bin/basename {} \; | LC_ALL=C /usr/bin/sort)"
test "$actual_resources" = "$expected_resources"
test -z "$(/usr/bin/find "$resources" -mindepth 1 -maxdepth 1 ! -type f -print -quit)"

binary_contains "$executable" "$marker"
for key in "${environment_keys[@]}"; do
  binary_contains "$executable" "$key"
done

policy_command verify-app "$app" || fail "E2E smoke app signature is invalid"

preferences_before="$(policy_command snapshot-preferences "$HOME")" || \
  fail "Could not pin and snapshot PickVia E2E preferences"

test "$(policy_command app-identity "$app")" = "$app_identity" || \
  fail "E2E smoke app changed before launch"
policy_command verify-app "$app" || fail "E2E smoke app changed before launch"

policy_command launch-app "$app" "$helper_source" "$session_nonce" || \
  fail "E2E smoke missing-target supervision failed"

for _ in {1..30}; do
  /bin/sleep 0.1
  preferences_after="$(policy_command snapshot-preferences "$HOME")" || \
    fail "Could not revalidate PickVia E2E preferences"
  test "$preferences_before" = "$preferences_after" || \
    fail "PickVia E2E preference artifacts changed"
done

print -r -- "E2E smoke status: target-missing"

if /usr/sbin/spctl --assess --type execute "$app" >/dev/null 2>&1; then
  print -r -- "Gatekeeper assessment: accepted"
else
  print -r -- "Gatekeeper assessment: not accepted (expected for an ad-hoc signature)"
fi
