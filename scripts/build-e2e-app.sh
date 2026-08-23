#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
scratch_candidate="$repo_root/.build-e2e"
output_candidate="$repo_root/build-e2e"
scratch=""
output_root=""
output_identity=""
app=""
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
    mkdir -- "$candidate" || fail "Could not create build root: $candidate"
  fi
  [[ -d "$candidate" && ! -L "$candidate" ]] || fail "Build root is not physical"

  physical_root="$(cd "$candidate" && pwd -P)" || fail "Could not resolve build root"
  [[ "$physical_root" == "$repo_root/$expected_name" ]] || \
    fail "Build root resolved outside the repository"
  [[ "${physical_root:h}" == "$repo_root" ]] || fail "Build root parent mismatch"
  REPLY="$physical_root"
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
  [[ "$(/usr/bin/stat -f '%d:%i' .)" == "$output_identity" ]] || \
    fail "Pinned output root identity changed"
  [[ "$(pwd -P)" == "$output_root" ]] || fail "Pinned output root path changed"
}

assert_no_symlink_components "$repo_root"
prepare_physical_repo_child "$scratch_candidate" ".build-e2e"
scratch="$REPLY"
prepare_physical_repo_child "$output_candidate" "build-e2e"
output_root="$REPLY"

test -s "$app_icon"
test -s "$menu_icon"

cd "$repo_root"
swift build -c release \
  --scratch-path "$scratch" \
  -Xswiftc -DPICKVIA_E2E_AUTOMATION \
  -Xswiftc -warnings-as-errors

prepare_physical_repo_child "$scratch_candidate" ".build-e2e"
scratch="$REPLY"
prepare_physical_repo_child "$output_candidate" "build-e2e"
output_root="$REPLY"

test -x "$scratch/release/PickVia"

pin_output_root
assert_output_root_current

app="PickVia E2E.app"
contents="$app/Contents"
resources="$contents/Resources"
if [[ -e "$app" || -L "$app" ]]; then
  [[ -d "$app" && ! -L "$app" ]] || fail "Refusing non-directory app path"
fi
rm -rf -- "$app"
assert_output_root_current
mkdir -p "$contents/MacOS" "$resources"
assert_output_root_current
cp "$scratch/release/PickVia" "$contents/MacOS/PickVia"
assert_output_root_current
cp "$repo_root/Support/Info.plist" "$contents/Info.plist"
assert_output_root_current
cp "$app_icon" "$resources/PickVia.icns"
assert_output_root_current
cp "$menu_icon" "$resources/PickViaMenuBarTemplate.png"
assert_output_root_current
chmod +x "$contents/MacOS/PickVia"
assert_output_root_current

/usr/libexec/PlistBuddy -c \
  "Set :CFBundleIdentifier dev.bozhenpeng.PickVia.E2E" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName PickVia E2E" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PickViaE2EAutomation bool true" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Add :PickViaE2EAutomationMarker string PICKVIA_E2E_AUTOMATION_ENABLED" \
  "$contents/Info.plist"
assert_output_root_current

/usr/bin/codesign --force --deep --sign - "$app"
assert_output_root_current

print -r -- "$output_root/$app"
