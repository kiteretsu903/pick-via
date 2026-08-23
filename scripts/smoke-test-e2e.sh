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
expected_status='{"outcome":"target-missing","session":"smoke_session_0123456789"}'
environment_keys=(
  PICKVIA_E2E_TARGET_ID
  PICKVIA_E2E_BUNDLE_ID
  PICKVIA_E2E_MODE
  PICKVIA_E2E_SESSION_NONCE
  PICKVIA_E2E_SUPPORT_DIR
  PICKVIA_E2E_STATUS_FIFO
)
runtime_root=""
runtime_pid=""
runtime_identity=""
status_fd=""

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

wait_child_bounded() {
  local child_pid="$1"
  local attempts="$2"
  local exit_status
  local index=0

  while (( index < attempts )); do
    if ! /bin/kill -0 "$child_pid" 2>/dev/null; then
      set +e
      wait "$child_pid" 2>/dev/null
      exit_status=$?
      set -e
      REPLY="$exit_status"
      return 0
    fi
    /bin/sleep 0.05
    (( index += 1 ))
  done
  return 1
}

stop_child_bounded() {
  local child_pid="$1"

  runtime_process_is_exact || return 1
  /bin/kill -TERM "$child_pid" 2>/dev/null || true
  if wait_child_bounded "$child_pid" 40; then
    return 0
  fi
  /bin/kill -KILL "$child_pid" 2>/dev/null || true
  wait_child_bounded "$child_pid" 40 || return 1
}

runtime_process_is_exact() {
  local current_identity

  [[ -n "$runtime_pid" && -n "$runtime_identity" ]] || return 1
  current_identity="$(policy_command process-identity \
    "$runtime_pid" "$executable")" || return 1
  [[ "$current_identity" == "$runtime_identity" ]]
}

cleanup_runtime() {
  if [[ -n "$runtime_pid" ]] && /bin/kill -0 "$runtime_pid" 2>/dev/null; then
    if runtime_process_is_exact; then
      stop_child_bounded "$runtime_pid" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$status_fd" ]]; then
    exec {status_fd}>&-
    status_fd=""
  fi
  if [[ -n "$runtime_root" ]]; then
    /bin/rm -rf -- "$runtime_root"
  fi
}
trap cleanup_runtime EXIT HUP INT TERM

binary_contains() {
  local binary="$1"
  local needle="$2"
  /usr/bin/grep -Fq "$needle" < <(/usr/bin/strings "$binary")
}

runtime_root="$(/usr/bin/mktemp -d /private/tmp/pickvia-e2e-smoke.XXXXXX)"
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
/usr/bin/mkfifo -m 600 "$runtime_root/status.fifo"
exec {status_fd}<>"$runtime_root/status.fifo"

policy_command compile-helper \
  "$helper_source" "$runtime_root/open_with_app" "$runtime_root" || \
  fail "E2E smoke helper compilation failed"

test "$(policy_command app-identity "$app")" = "$app_identity" || \
  fail "E2E smoke app changed before launch"
policy_command verify-app "$app" || fail "E2E smoke app changed before launch"

/usr/bin/env -i \
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
  /bin/kill -0 "$runtime_pid" 2>/dev/null && break
  /bin/sleep 0.05
done
/bin/kill -0 "$runtime_pid" 2>/dev/null || fail "E2E smoke app did not remain active"
for _ in {1..40}; do
  runtime_identity="$(policy_command process-identity \
    "$runtime_pid" "$executable")" 2>/dev/null && break
  /bin/sleep 0.05
done
[[ -n "$runtime_identity" ]] || fail "E2E smoke app identity could not be pinned"

policy_command run-helper \
  "$runtime_root/open_with_app" "$app" "$runtime_pid" "$runtime_root" || \
  fail "E2E smoke helper failed"

status_line=""
IFS= read -r -t 10 status_line <&$status_fd || fail "E2E smoke status timed out"
test "$status_line" = "$expected_status" || fail "Unexpected E2E smoke status"

if ! runtime_process_is_exact; then
  runtime_pid=""
  fail "E2E smoke app generation changed before termination"
fi
/bin/kill -TERM "$runtime_pid" 2>/dev/null || fail "E2E smoke app exited unexpectedly"
if ! wait_child_bounded "$runtime_pid" 80; then
  if ! runtime_process_is_exact; then
    runtime_pid=""
    fail "E2E smoke app generation changed during termination"
  fi
  /bin/kill -KILL "$runtime_pid" 2>/dev/null || true
  if wait_child_bounded "$runtime_pid" 40; then
    runtime_pid=""
  fi
  fail "E2E smoke app ignored bounded termination"
fi
runtime_status="$REPLY"
runtime_pid=""
test "$runtime_status" -eq 143 || fail "Unexpected E2E smoke app exit"

for _ in {1..30}; do
  /bin/sleep 0.1
  preferences_after="$(policy_command snapshot-preferences "$HOME")" || \
    fail "Could not revalidate PickVia E2E preferences"
  test "$preferences_before" = "$preferences_after" || \
    fail "PickVia E2E preference artifacts changed"
done

test -z "$(/usr/bin/find "$runtime_root" -mindepth 1 -type l -print -quit)"
print -r -- "E2E smoke status: target-missing"

if /usr/sbin/spctl --assess --type execute "$app" >/dev/null 2>&1; then
  print -r -- "Gatekeeper assessment: accepted"
else
  print -r -- "Gatekeeper assessment: not accepted (expected for an ad-hoc signature)"
fi
