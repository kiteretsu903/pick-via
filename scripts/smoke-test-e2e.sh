#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
app="${1:-$repo_root/build-e2e/PickVia E2E.app}"
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/PickVia"
resources="$app/Contents/Resources"
helper_source="$repo_root/scripts/browser-e2e/open_with_app.swift"
marker="PICKVIA_E2E_AUTOMATION_ENABLED"
session_nonce="smoke_session_0123456789"
expected_status='{"outcome":"target-missing","session":"smoke_session_0123456789"}'
environment_keys=(
  PICKVIA_E2E_TARGET_ID
  PICKVIA_E2E_BUNDLE_ID
  PICKVIA_E2E_MODE
  PICKVIA_E2E_SESSION_NONCE
  PICKVIA_E2E_SUPPORT_DIR
  PICKVIA_E2E_STATUS_FIFO
)
preferences_root="${HOME:?}/Library/Preferences"
preferences_by_host="$HOME/Library/Preferences/ByHost"
runtime_root=""
runtime_pid=""
helper_pid=""
status_fd=""

fail() {
  print -u2 -r -- "$1"
  exit 1
}

wait_child_bounded() {
  local child_pid="$1"
  local attempts="$2"
  local exit_status
  local index=0

  while (( index < attempts )); do
    if ! kill -0 "$child_pid" 2>/dev/null; then
      set +e
      wait "$child_pid" 2>/dev/null
      exit_status=$?
      set -e
      REPLY="$exit_status"
      return 0
    fi
    sleep 0.05
    (( index += 1 ))
  done
  return 1
}

stop_child_bounded() {
  local child_pid="$1"

  kill -TERM "$child_pid" 2>/dev/null || true
  if wait_child_bounded "$child_pid" 40; then
    return 0
  fi
  kill -KILL "$child_pid" 2>/dev/null || true
  wait_child_bounded "$child_pid" 40 || return 1
}

cleanup_runtime() {
  if [[ -n "$helper_pid" ]] && kill -0 "$helper_pid" 2>/dev/null; then
    stop_child_bounded "$helper_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$runtime_pid" ]] && kill -0 "$runtime_pid" 2>/dev/null; then
    stop_child_bounded "$runtime_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$status_fd" ]]; then
    exec {status_fd}>&-
    status_fd=""
  fi
  if [[ -n "$runtime_root" ]]; then
    rm -rf -- "$runtime_root"
  fi
}
trap cleanup_runtime EXIT HUP INT TERM

binary_contains() {
  local binary="$1"
  local needle="$2"
  grep -Fq "$needle" < <(strings "$binary")
}

snapshot_preferences() {
  local destination="$1"
  local unsorted="$destination.unsorted"
  local directory
  local artifact
  local relative
  local metadata
  local digest

  : > "$unsorted"
  for directory in "$preferences_root" "$preferences_by_host"; do
    [[ -d "$directory" ]] || continue
    while IFS= read -r -d '' artifact; do
      [[ -f "$artifact" && ! -L "$artifact" ]] || \
        fail "Unsafe PickVia E2E preference artifact"
      relative="${artifact#$preferences_root/}"
      metadata="$(/usr/bin/stat -f '%d:%i:%z:%p:%m' "$artifact")" || \
        fail "Could not inspect PickVia E2E preference artifact"
      digest="$(shasum -a 256 "$artifact" | awk '{print $1}')" || \
        fail "Could not snapshot PickVia E2E preference artifact"
      print -r -- "$relative\t$metadata\t$digest" >> "$unsorted"
    done < <(
      find -P "$directory" -mindepth 1 -maxdepth 1 \
        -name 'dev.bozhenpeng.PickVia.E2E*' -print0
    )
  done
  LC_ALL=C sort "$unsorted" > "$destination"
  rm -f -- "$unsorted"
}

runtime_root="$(mktemp -d /private/tmp/pickvia-e2e-smoke.XXXXXX)"
case "$runtime_root" in
  /private/tmp/pickvia-e2e-smoke.*) ;;
  *) fail "Unsafe E2E smoke root" ;;
esac
[[ "$(cd "$runtime_root" && pwd -P)" == "$runtime_root" ]] || \
  fail "E2E smoke root is not physical"

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

snapshot_preferences "$runtime_root/preferences-before"
mkfifo -m 600 "$runtime_root/status.fifo"
exec {status_fd}<>"$runtime_root/status.fifo"

env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=en_US.UTF-8 \
  LC_CTYPE=UTF-8 \
  TMPDIR="$runtime_root" \
  CFFIXED_USER_HOME="$runtime_root" \
  /usr/bin/xcrun swiftc -swift-version 6 -warnings-as-errors \
    "$helper_source" -o "$runtime_root/open_with_app" >/dev/null 2>&1 &
helper_pid=$!
if ! wait_child_bounded "$helper_pid" 600; then
  stop_child_bounded "$helper_pid" >/dev/null 2>&1 || true
  fail "E2E smoke helper compilation timed out"
fi
helper_status="$REPLY"
helper_pid=""
test "$helper_status" -eq 0 || fail "E2E smoke helper compilation failed"

env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=en_US.UTF-8 \
  LC_CTYPE=UTF-8 \
  TMPDIR="$runtime_root" \
  CFFIXED_USER_HOME="$runtime_root" \
  PICKVIA_E2E_TARGET_ID='dev.bozhenpeng.PickVia.E2E.Missing||normal' \
  PICKVIA_E2E_BUNDLE_ID='dev.bozhenpeng.PickVia.E2E.Missing' \
  PICKVIA_E2E_MODE='normal' \
  PICKVIA_E2E_SESSION_NONCE="$session_nonce" \
  PICKVIA_E2E_SUPPORT_DIR="$runtime_root" \
  PICKVIA_E2E_STATUS_FIFO="$runtime_root/status.fifo" \
  "$executable" >/dev/null 2>&1 &
runtime_pid=$!

for _ in {1..40}; do
  kill -0 "$runtime_pid" 2>/dev/null && break
  sleep 0.05
done
kill -0 "$runtime_pid" 2>/dev/null || fail "E2E smoke app did not remain active"

{
  print -n -r -- 'https://127.0.0.1/pickvia-e2e-smoke' | env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    LANG=en_US.UTF-8 \
    LC_CTYPE=UTF-8 \
    TMPDIR="$runtime_root" \
    CFFIXED_USER_HOME="$runtime_root" \
    "$runtime_root/open_with_app" "$app" "$runtime_pid"
} >/dev/null 2>&1 &
helper_pid=$!

status_line=""
IFS= read -r -t 10 status_line <&$status_fd || fail "E2E smoke status timed out"
test "$status_line" = "$expected_status" || fail "Unexpected E2E smoke status"

if ! wait_child_bounded "$helper_pid" 200; then
  stop_child_bounded "$helper_pid" >/dev/null 2>&1 || true
  fail "E2E smoke helper timed out"
fi
helper_status="$REPLY"
helper_pid=""
test "$helper_status" -eq 0 || fail "E2E smoke helper failed"

kill -TERM "$runtime_pid" 2>/dev/null || fail "E2E smoke app exited unexpectedly"
if ! wait_child_bounded "$runtime_pid" 80; then
  kill -KILL "$runtime_pid" 2>/dev/null || true
  if wait_child_bounded "$runtime_pid" 40; then
    runtime_pid=""
  fi
  fail "E2E smoke app ignored bounded termination"
fi
runtime_status="$REPLY"
runtime_pid=""
test "$runtime_status" -eq 143 || fail "Unexpected E2E smoke app exit"

for _ in {1..30}; do
  sleep 0.1
  snapshot_preferences "$runtime_root/preferences-after"
  cmp -s "$runtime_root/preferences-before" "$runtime_root/preferences-after" || \
    fail "PickVia E2E preference artifacts changed"
done

test -z "$(find "$runtime_root" -mindepth 1 -type l -print -quit)"
print -r -- "E2E smoke status: target-missing"

if /usr/sbin/spctl --assess --type execute "$app" >/dev/null 2>&1; then
  print -r -- "Gatekeeper assessment: accepted"
else
  print -r -- "Gatekeeper assessment: not accepted (expected for an ad-hoc signature)"
fi
