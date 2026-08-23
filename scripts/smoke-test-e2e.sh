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
real_preferences="$HOME/Library/Preferences/dev.bozhenpeng.PickVia.E2E.plist"
preferences_existed_before=false
preferences_hash_before=""

if [[ -e "$real_preferences" ]]; then
  test -f "$real_preferences"
  test ! -L "$real_preferences"
  preferences_existed_before=true
  preferences_hash_before="$(shasum -a 256 "$real_preferences" | awk '{print $1}')"
fi

runtime_root="$(mktemp -d /private/tmp/pickvia-e2e-smoke.XXXXXX)"
case "$runtime_root" in
  /private/tmp/pickvia-e2e-smoke.*) ;;
  *)
    print -u2 -r -- "Unsafe E2E smoke root: $runtime_root"
    exit 1
    ;;
esac
runtime_pid=""

cleanup_runtime() {
  if [[ -n "$runtime_pid" ]] && kill -0 "$runtime_pid" 2>/dev/null; then
    kill -TERM "$runtime_pid" 2>/dev/null || true
    wait "$runtime_pid" 2>/dev/null || true
  fi
  rm -rf -- "$runtime_root"
}
trap cleanup_runtime EXIT HUP INT TERM

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

mkfifo -m 600 "$runtime_root/status.fifo"
env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=en_US.UTF-8 \
  LC_CTYPE=UTF-8 \
  TMPDIR="$runtime_root" \
  CFFIXED_USER_HOME="$runtime_root" \
  PICKVIA_E2E_TARGET_ID='com.microsoft.edgemac||normal' \
  PICKVIA_E2E_BUNDLE_ID='com.microsoft.edgemac' \
  PICKVIA_E2E_MODE='normal' \
  PICKVIA_E2E_SESSION_NONCE='smoke_session_0123456789' \
  PICKVIA_E2E_SUPPORT_DIR="$runtime_root" \
  PICKVIA_E2E_STATUS_FIFO="$runtime_root/status.fifo" \
  "$executable" >/dev/null 2>&1 &
runtime_pid=$!

for _ in {1..20}; do
  kill -0 "$runtime_pid" 2>/dev/null && break
  sleep 0.05
done
kill -0 "$runtime_pid"
sleep 0.25
kill -TERM "$runtime_pid"
wait "$runtime_pid" 2>/dev/null || true
runtime_pid=""

if $preferences_existed_before; then
  test -f "$real_preferences"
  test ! -L "$real_preferences"
  test "$(shasum -a 256 "$real_preferences" | awk '{print $1}')" = \
    "$preferences_hash_before"
else
  test ! -e "$real_preferences"
fi

test -z "$(find "$runtime_root" -mindepth 1 -maxdepth 1 -type l -print -quit)"

if /usr/sbin/spctl --assess --type execute "$app" >/dev/null 2>&1; then
  print -r -- "Gatekeeper assessment: accepted"
else
  print -r -- "Gatekeeper assessment: not accepted (expected for an ad-hoc signature)"
fi
