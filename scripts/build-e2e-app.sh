#!/bin/zsh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch_candidate="$repo_root/.build-e2e"
output_candidate="$repo_root/build-e2e"
scratch=""
output_root=""
output_identity=""
scratch_identity=""
scratch_executable_identity=""
scratch_fd=""
staging_identity=""
app=""
staging=""
contents=""
resources=""
app_icon="$repo_root/Support/Icons/PickVia.icns"
menu_icon="$repo_root/Support/Icons/PickViaMenuBarTemplate.png"

fail() {
  print -u2 -r -- "$1"
  exit 1
}

assert_no_symlink_components() {
  local cursor="$1"

  while [[ "$cursor" != "/" ]]; do
    [[ ! -L "$cursor" ]] || fail "Refusing symlinked parent component: $cursor"
    cursor="${cursor:h}"
  done
}

prepare_physical_repo_child() {
  local candidate="$1"
  local expected_name="$2"
  local physical_root

  [[ "${candidate:h}" == "$repo_root" ]] || fail "Root is outside the repository"
  [[ ! -L "$candidate" ]] || fail "Refusing symlinked build root: $candidate"
  if [[ -e "$candidate" ]]; then
    [[ -d "$candidate" ]] || fail "Build root is not a directory: $candidate"
  else
    /bin/mkdir -- "$candidate" || fail "Could not create build root: $candidate"
  fi
  [[ -d "$candidate" && ! -L "$candidate" ]] || fail "Build root is not physical"

  physical_root="$(cd "$candidate" && pwd -P)" || fail "Could not resolve build root"
  [[ "$physical_root" == "$repo_root/$expected_name" ]] || \
    fail "Build root resolved outside the repository"
  [[ "${physical_root:h}" == "$repo_root" ]] || fail "Build root parent mismatch"
  REPLY="$physical_root"
}

run_contract_hook() {
  local phase="$1"
  local hook="${PICKVIA_BUILD_E2E_CONTRACT_HOOK:-}"

  [[ -n "$hook" ]] || return 0
  [[ "$repo_root" == /private/tmp/pickvia-e2e-build-isolation.*/* ]] || \
    fail "Build contract hook is forbidden outside its fixture"
  [[ "$hook" == /private/tmp/pickvia-e2e-build-isolation.*/* ]] || \
    fail "Build contract hook is outside its fixture"
  [[ -f "$hook" && -x "$hook" && ! -L "$hook" ]] || \
    fail "Build contract hook is invalid"
  "$hook" "$phase"
}

descriptor_identity() {
  /usr/bin/python3 -c \
    'import os, sys; value = os.fstat(int(sys.argv[1])); print(f"{value.st_dev}:{value.st_ino}:{value.st_size}:{value.st_mode:o}")' \
    "$1"
}

pin_scratch_executable() {
  local executable="$scratch/release/PickVia"

  scratch_identity="$(/usr/bin/stat -f '%d:%i' "$scratch")" || \
    fail "Could not identify scratch root"
  exec {scratch_fd}<"$executable" || fail "Could not pin E2E executable"
  scratch_executable_identity="$(descriptor_identity "$scratch_fd")" || \
    fail "Could not identify pinned E2E executable"
  [[ "$(/usr/bin/stat -f '%d:%i:%z:%p' "$executable")" == \
    "$scratch_executable_identity" ]] || fail "E2E executable changed while pinning"
}

assert_scratch_current() {
  [[ -d "$scratch_candidate" && ! -L "$scratch_candidate" ]] || \
    fail "Scratch root path changed"
  [[ "$(cd "$scratch_candidate" && pwd -P)" == "$scratch" ]] || \
    fail "Scratch root path changed"
  [[ "$(/usr/bin/stat -f '%d:%i' "$scratch_candidate")" == "$scratch_identity" ]] || \
    fail "Scratch root identity changed"
  [[ "$(descriptor_identity "$scratch_fd")" == \
    "$scratch_executable_identity" ]] || fail "Pinned E2E executable changed"
}

pin_output_root() {
  cd "$output_root" || fail "Could not enter output root"
  [[ "$(pwd -P)" == "$output_root" ]] || fail "Output root path changed"
  output_identity="$(/usr/bin/stat -f '%d:%i' .)" || \
    fail "Could not identify output root"
}

assert_output_root_current() {
  local candidate_identity
  local candidate_physical

  [[ -d "$output_candidate" && ! -L "$output_candidate" ]] || \
    fail "Output root path changed"
  candidate_physical="$(cd "$output_candidate" && pwd -P)" || \
    fail "Could not resolve current output root"
  [[ "$candidate_physical" == "$output_root" ]] || fail "Output root path changed"
  candidate_identity="$(/usr/bin/stat -f '%d:%i' "$output_candidate")" || \
    fail "Could not identify current output root"
  [[ "$candidate_identity" == "$output_identity" ]] || fail "Output root identity changed"
}

assert_staging_current() {
  assert_output_root_current
  [[ "$(/usr/bin/stat -f '%d:%i' .)" == "$staging_identity" ]] || \
    fail "Pinned staging root identity changed"
  [[ "$(/usr/bin/stat -f '%d:%i' "$output_root/$staging")" == "$staging_identity" ]] || \
    fail "Staging root identity changed"
  [[ "$(pwd -P)" == "$output_root/$staging" ]] || fail "Staging root path changed"
}

assert_no_symlink_components "$repo_root"
prepare_physical_repo_child "$scratch_candidate" ".build-e2e"
scratch="$REPLY"
prepare_physical_repo_child "$output_candidate" "build-e2e"
output_root="$REPLY"

test -s "$app_icon"
test -s "$menu_icon"

cd "$repo_root"
if [[ -n "${PICKVIA_BUILD_E2E_CONTRACT_HOOK:-}" ]]; then
  run_contract_hook build
else
  /usr/bin/swift build -c release \
    --scratch-path "$scratch" \
    -Xswiftc -DPICKVIA_E2E_AUTOMATION \
    -Xswiftc -warnings-as-errors
fi

prepare_physical_repo_child "$scratch_candidate" ".build-e2e"
scratch="$REPLY"
prepare_physical_repo_child "$output_candidate" "build-e2e"
output_root="$REPLY"

test -x "$scratch/release/PickVia"
pin_scratch_executable
assert_scratch_current

pin_output_root
assert_output_root_current

app="PickVia E2E.app"
staging="$app"
contents="Contents"
resources="$contents/Resources"
if [[ -e "$app" || -L "$app" ]]; then
  [[ -d "$app" && ! -L "$app" ]] || fail "Refusing non-directory app path"
fi
run_contract_hook before-output-removal
/bin/rm -rf -- "$app"
assert_output_root_current
run_contract_hook before-app-reservation
/bin/mkdir -- "$app" || fail "Concurrent output entry preserved"
cd "$app" || fail "Could not enter staging root"
staging_identity="$(/usr/bin/stat -f '%d:%i' .)" || fail "Could not identify staging root"
assert_staging_current
/bin/mkdir -p "$contents/MacOS" "$resources"
assert_staging_current
run_contract_hook before-scratch-copy
assert_scratch_current
/bin/cp "/dev/fd/$scratch_fd" "$contents/MacOS/PickVia"
assert_scratch_current
assert_staging_current
/bin/cp "$repo_root/Support/Info.plist" "$contents/Info.plist"
assert_staging_current
/bin/cp "$app_icon" "$resources/PickVia.icns"
assert_staging_current
/bin/cp "$menu_icon" "$resources/PickViaMenuBarTemplate.png"
assert_staging_current
/bin/chmod +x "$contents/MacOS/PickVia"
assert_staging_current

/usr/libexec/PlistBuddy -c \
  "Set :CFBundleIdentifier dev.bozhenpeng.PickVia.E2E" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName PickVia E2E" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PickViaE2EAutomation bool true" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Add :PickViaE2EAutomationMarker string PICKVIA_E2E_AUTOMATION_ENABLED" \
  "$contents/Info.plist"
assert_staging_current

/usr/bin/codesign --force --deep --sign - .
assert_staging_current

cd .. || fail "Could not return to output root"
assert_output_root_current
[[ "$(/usr/bin/stat -f '%d:%i' .)" == "$output_identity" ]] || \
  fail "Pinned output root identity changed"
[[ "$(pwd -P)" == "$output_root" ]] || fail "Pinned output root path changed"
exec {scratch_fd}>&-
scratch_fd=""

print -r -- "$output_root/$app"
