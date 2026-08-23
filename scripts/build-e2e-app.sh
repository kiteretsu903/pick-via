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
app_fd=""
contents_fd=""
app=""
app_icon="$repo_root/Support/Icons/PickVia.icns"
menu_icon="$repo_root/Support/Icons/PickViaMenuBarTemplate.png"
bundle_helper="$repo_root/scripts/browser-e2e/build_e2e_bundle.py"

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
    'import hashlib, os, sys; descriptor = int(sys.argv[1]); before = os.fstat(descriptor); os.lseek(descriptor, 0, os.SEEK_SET); digest = hashlib.sha256(); [digest.update(chunk) for chunk in iter(lambda: os.read(descriptor, 65536), b"")]; after = os.fstat(descriptor); fields = ("st_dev", "st_ino", "st_size", "st_mode", "st_mtime_ns", "st_ctime_ns"); assert all(getattr(before, field) == getattr(after, field) for field in fields); print(":".join([str(before.st_dev), str(before.st_ino), str(before.st_size), format(before.st_mode, "o"), str(before.st_mtime_ns), str(before.st_ctime_ns), digest.hexdigest()]))' \
    "$1"
}

directory_descriptor_identity() {
  /usr/bin/python3 -c \
    'import os, stat, sys; value = os.fstat(int(sys.argv[1])); assert stat.S_ISDIR(value.st_mode); print(f"{value.st_dev}:{value.st_ino}:{value.st_mode:o}")' \
    "$1"
}

assert_directory_entries() {
  local directory_fd="$1"
  local expected="$2"
  local actual

  actual="$(/usr/bin/python3 -c \
    'import os, stat, sys; descriptor = int(sys.argv[1]); names = sorted(os.listdir(descriptor)); assert all(not stat.S_ISLNK(os.stat(name, dir_fd=descriptor, follow_symlinks=False).st_mode) for name in names); print("\n".join(names))' \
    "$directory_fd")" || fail "Could not inspect pinned bundle directory"
  [[ "$actual" == "$expected" ]] || fail "Bundle contains unexpected entries"
}

path_content_identity() {
  local source="$1"
  local source_fd
  local identity

  exec {source_fd}<"$source" || return 1
  identity="$(descriptor_identity "$source_fd")" || return 1
  exec {source_fd}>&-
  print -r -- "$identity"
}

path_directory_identity() {
  local source="$1"
  local source_fd
  local identity

  exec {source_fd}<"$source" || return 1
  identity="$(directory_descriptor_identity "$source_fd")" || return 1
  exec {source_fd}>&-
  print -r -- "$identity"
}

pin_scratch_executable() {
  local executable="$scratch/release/PickVia"

  scratch_identity="$(/usr/bin/stat -f '%d:%i' "$scratch")" || \
    fail "Could not identify scratch root"
  exec {scratch_fd}<"$executable" || fail "Could not pin E2E executable"
  scratch_executable_identity="$(descriptor_identity "$scratch_fd")" || \
    fail "Could not identify pinned E2E executable"
  [[ "$(path_content_identity "$executable")" == \
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
  [[ "$(path_content_identity "$scratch/release/PickVia")" == \
    "$scratch_executable_identity" ]] || fail "E2E executable path changed"
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

assert_no_symlink_components "$repo_root"
prepare_physical_repo_child "$scratch_candidate" ".build-e2e"
scratch="$REPLY"
prepare_physical_repo_child "$output_candidate" "build-e2e"
output_root="$REPLY"

test -s "$app_icon"
test -s "$menu_icon"
test -f "$bundle_helper"

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
app_existed=false
if [[ -e "$app" || -L "$app" ]]; then
  [[ -d "$app" && ! -L "$app" ]] || fail "Refusing non-directory app path"
  app_existed=true
else
  run_contract_hook before-app-reservation
  /bin/mkdir -- "$app" || fail "Concurrent output entry preserved"
fi
app_identity="$(path_directory_identity "$app")" || fail "Could not pin app entry"
run_contract_hook before-app-entry-open
cd "$app" || fail "Could not enter app root"
[[ "$(path_directory_identity .)" == "$app_identity" ]] || fail "App entry changed before open"
[[ "$(pwd -P)" == "$output_root/$app" ]] || fail "App entry path changed"
exec {app_fd}<. || fail "Could not pin app directory"
[[ "$(directory_descriptor_identity "$app_fd")" == "$app_identity" ]] || \
  fail "App entry identity mismatch"
if $app_existed; then
  assert_directory_entries "$app_fd" "Contents"
else
  assert_directory_entries "$app_fd" ""
fi

run_contract_hook before-contents-open
if [[ ! -e Contents && ! -L Contents ]]; then
  $app_existed && fail "Existing app is missing Contents"
  /bin/mkdir -- Contents || fail "Could not reserve Contents"
fi
[[ -d Contents && ! -L Contents ]] || fail "Contents is not a physical directory"
contents_identity="$(path_directory_identity Contents)" || fail "Could not pin Contents"
exec {contents_fd}<Contents || fail "Could not open Contents"
[[ "$(directory_descriptor_identity "$contents_fd")" == "$contents_identity" ]] || \
  fail "Contents identity mismatch"
cd Contents || fail "Could not enter pinned Contents"
[[ "$(path_directory_identity .)" == "$contents_identity" ]] || \
  fail "Contents working directory identity mismatch"
if $app_existed; then
  assert_directory_entries "$contents_fd" $'Info.plist\nMacOS\nResources\n_CodeSignature'
else
  assert_directory_entries "$contents_fd" ""
  /bin/mkdir -- MacOS Resources _CodeSignature
fi

/usr/bin/python3 "$bundle_helper" \
  "$repo_root" "$output_root/$app" "$app_fd" "$contents_fd" \
  "$scratch/release/PickVia" "$scratch_fd" "$repo_root/Support/Info.plist" \
  "$app_icon" "$menu_icon" "$app_existed" || fail "Pinned bundle construction failed"
[[ "$(directory_descriptor_identity "$app_fd")" == "$app_identity" ]] || \
  fail "Pinned app changed during signing"
assert_directory_entries "$app_fd" "Contents"
assert_directory_entries "$contents_fd" $'Info.plist\nMacOS\nResources\n_CodeSignature'
[[ "$(path_directory_identity "$output_root/$app")" == "$app_identity" ]] || \
  fail "Public app entry changed after signing"
[[ "$(path_directory_identity "$output_root/$app/Contents")" == "$contents_identity" ]] || \
  fail "Public Contents changed after signing"

exec {contents_fd}>&-
exec {app_fd}>&-
exec {scratch_fd}>&-
scratch_fd=""

print -r -- "$output_root/$app"
