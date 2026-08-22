#!/bin/zsh
set -euo pipefail

app="${1:-build-e2e/PickVia E2E.app}"
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/PickVia"
resources="$app/Contents/Resources"
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

test -x "$executable"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = \
  "dev.bozhenpeng.PickVia.E2E"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist")" = "PickVia E2E"
test "$(/usr/libexec/PlistBuddy -c 'Print :PickViaE2EAutomation' "$plist")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :PickViaE2EAutomationMarker' "$plist")" = "$marker"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" = "14.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist")" = "true"

test "$(plutil -extract CFBundleURLTypes raw -o - "$plist")" -eq 2
test "$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes raw -o - "$plist")" -eq 2
scheme0="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$plist")"
scheme1="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.1 raw -o - "$plist")"
test "$scheme0:$scheme1" = "http:https" || test "$scheme0:$scheme1" = "https:http"
test "$(plutil -extract CFBundleURLTypes.1.CFBundleURLSchemes raw -o - "$plist")" -eq 1
test "$(plutil -extract CFBundleURLTypes.1.CFBundleURLSchemes.0 raw -o - "$plist")" = \
  "mailto"

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" = "PickVia"
test -s "$resources/PickVia.icns"
test -s "$resources/PickViaMenuBarTemplate.png"
test "$(sips -g pixelWidth "$resources/PickViaMenuBarTemplate.png" | awk '/pixelWidth/ {print $2}')" = \
  "44"
test "$(sips -g pixelHeight "$resources/PickViaMenuBarTemplate.png" | awk '/pixelHeight/ {print $2}')" = \
  "44"

expected_resources=$'PickVia.icns\nPickViaMenuBarTemplate.png'
actual_resources="$(find "$resources" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort)"
test "$actual_resources" = "$expected_resources"
test -z "$(find "$resources" -mindepth 1 -maxdepth 1 ! -type f -print -quit)"

binary_contains "$executable" "$marker"
for key in "${environment_keys[@]}"; do
  binary_contains "$executable" "$key"
done

/usr/bin/codesign --verify --deep --strict "$app"

if /usr/sbin/spctl --assess --type execute "$app" >/dev/null 2>&1; then
  print -r -- "Gatekeeper assessment: accepted"
else
  print -r -- "Gatekeeper assessment: not accepted (expected for an ad-hoc signature)"
fi
