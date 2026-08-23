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
macos_fd=""
resources_fd=""
app=""
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

copy_descriptor_to_entry() {
  local source_fd="$1"
  local directory_fd="$2"
  local name="$3"
  local mode="$4"

  /usr/bin/python3 -c \
    'import hashlib, os, stat, sys; source_fd, directory_fd, name, mode = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], int(sys.argv[4], 8); source_before = os.fstat(source_fd); assert stat.S_ISREG(source_before.st_mode); flags = os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW; created = False
try:
 destination_fd = os.open(name, flags, dir_fd=directory_fd)
except PermissionError:
 read_fd = os.open(name, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW, dir_fd=directory_fd); pinned = os.fstat(read_fd); os.fchmod(read_fd, pinned.st_mode | stat.S_IWUSR); os.close(read_fd); destination_fd = os.open(name, flags, dir_fd=directory_fd); reopened = os.fstat(destination_fd); assert (pinned.st_dev, pinned.st_ino) == (reopened.st_dev, reopened.st_ino)
except FileNotFoundError:
 destination_fd = os.open(name, flags | os.O_CREAT | os.O_EXCL, mode, dir_fd=directory_fd); created = True
try:
 destination_before = os.fstat(destination_fd); named_before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False); assert (destination_before.st_dev, destination_before.st_ino) == (named_before.st_dev, named_before.st_ino); os.lseek(source_fd, 0, os.SEEK_SET); os.ftruncate(destination_fd, 0); os.lseek(destination_fd, 0, os.SEEK_SET); source_hash = hashlib.sha256(); destination_hash = hashlib.sha256()
 while True:
  chunk = os.read(source_fd, 65536)
  if not chunk: break
  source_hash.update(chunk); view = memoryview(chunk)
  while view: view = view[os.write(destination_fd, view):]
 os.fchmod(destination_fd, mode); os.fsync(destination_fd); os.lseek(destination_fd, 0, os.SEEK_SET)
 while True:
  chunk = os.read(destination_fd, 65536)
  if not chunk: break
  destination_hash.update(chunk)
 source_after = os.fstat(source_fd); destination_after = os.fstat(destination_fd); named_after = os.stat(name, dir_fd=directory_fd, follow_symlinks=False); fields = ("st_dev", "st_ino", "st_size", "st_mode", "st_mtime_ns", "st_ctime_ns"); assert all(getattr(source_before, field) == getattr(source_after, field) for field in fields); assert (destination_after.st_dev, destination_after.st_ino) == (named_after.st_dev, named_after.st_ino); assert source_hash.digest() == destination_hash.digest(); assert destination_after.st_size == source_after.st_size
finally:
 os.close(destination_fd)' \
    "$source_fd" "$directory_fd" "$name" "$mode"
}

copy_path_to_entry() {
  local source="$1"
  local directory_fd="$2"
  local name="$3"
  local mode="$4"
  local source_fd

  exec {source_fd}<"$source" || fail "Could not pin bundle source"
  copy_descriptor_to_entry "$source_fd" "$directory_fd" "$name" "$mode" || \
    fail "Could not write pinned bundle entry"
  exec {source_fd}>&-
}

write_e2e_plist_to_entry() {
  local source="$1"
  local directory_fd="$2"

  /usr/bin/python3 -c \
    'import os, plistlib, stat, sys; source, directory_fd = sys.argv[1], int(sys.argv[2]); source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
 source_before = os.fstat(source_fd); data = bytearray()
 while True:
  chunk = os.read(source_fd, 65536)
  if not chunk: break
  data.extend(chunk)
 source_after = os.fstat(source_fd); assert (source_before.st_dev, source_before.st_ino, source_before.st_size, source_before.st_mtime_ns, source_before.st_ctime_ns) == (source_after.st_dev, source_after.st_ino, source_after.st_size, source_after.st_mtime_ns, source_after.st_ctime_ns); values = plistlib.loads(data); values["CFBundleIdentifier"] = "dev.bozhenpeng.PickVia.E2E"; values["CFBundleName"] = "PickVia E2E"; values["PickViaE2EAutomation"] = True; values["PickViaE2EAutomationMarker"] = "PICKVIA_E2E_AUTOMATION_ENABLED"; output = plistlib.dumps(values, fmt=plistlib.FMT_XML, sort_keys=True)
finally:
 os.close(source_fd)
flags = os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW
try:
 destination_fd = os.open("Info.plist", flags, dir_fd=directory_fd)
except FileNotFoundError:
 destination_fd = os.open("Info.plist", flags | os.O_CREAT | os.O_EXCL, 0o644, dir_fd=directory_fd)
try:
 before = os.fstat(destination_fd); named = os.stat("Info.plist", dir_fd=directory_fd, follow_symlinks=False); assert stat.S_ISREG(before.st_mode) and (before.st_dev, before.st_ino) == (named.st_dev, named.st_ino); os.ftruncate(destination_fd, 0); os.lseek(destination_fd, 0, os.SEEK_SET); view = memoryview(output)
 while view: view = view[os.write(destination_fd, view):]
 os.fchmod(destination_fd, 0o644); os.fsync(destination_fd); after = os.fstat(destination_fd); named_after = os.stat("Info.plist", dir_fd=directory_fd, follow_symlinks=False); assert (after.st_dev, after.st_ino, after.st_size) == (named_after.st_dev, named_after.st_ino, len(output))
finally:
 os.close(destination_fd)' \
    "$source" "$directory_fd" || fail "Could not write pinned Info.plist"
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

assert_exact_entries() {
  local expected="$1"
  local actual

  actual="$(/usr/bin/find . -mindepth 1 -maxdepth 1 -exec /usr/bin/basename {} \; | \
    LC_ALL=C /usr/bin/sort)"
  [[ "$actual" == "$expected" ]] || fail "Bundle contains unexpected entries"
  [[ -z "$(/usr/bin/find . -mindepth 1 -maxdepth 1 -type l -print -quit)" ]] || \
    fail "Bundle contains a symlink"
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
if $app_existed; then
  assert_directory_entries "$contents_fd" $'Info.plist\nMacOS\nResources\n_CodeSignature'
  [[ -d Contents/MacOS && ! -L Contents/MacOS ]] || fail "MacOS is not physical"
  [[ -d Contents/Resources && ! -L Contents/Resources ]] || fail "Resources is not physical"
  [[ -d Contents/_CodeSignature && ! -L Contents/_CodeSignature ]] || \
    fail "Signature directory is not physical"
else
  assert_directory_entries "$contents_fd" ""
  /bin/mkdir -- Contents/MacOS Contents/Resources
fi

exec {macos_fd}<Contents/MacOS || fail "Could not pin MacOS"
exec {resources_fd}<Contents/Resources || fail "Could not pin Resources"
if $app_existed; then
  assert_directory_entries "$macos_fd" "PickVia"
  assert_directory_entries "$resources_fd" $'PickVia.icns\nPickViaMenuBarTemplate.png'
  (
    cd Contents/_CodeSignature || exit 1
    assert_exact_entries "CodeResources"
  ) || fail "Signature structure is invalid"
else
  assert_directory_entries "$macos_fd" ""
  assert_directory_entries "$resources_fd" ""
fi

run_contract_hook before-scratch-copy
assert_scratch_current
copy_descriptor_to_entry "$scratch_fd" "$macos_fd" PickVia 755 || \
  fail "Could not write pinned E2E executable"
assert_scratch_current
write_e2e_plist_to_entry "$repo_root/Support/Info.plist" "$contents_fd"
copy_path_to_entry "$app_icon" "$resources_fd" PickVia.icns 644
copy_path_to_entry "$menu_icon" "$resources_fd" PickViaMenuBarTemplate.png 644
[[ "$(descriptor_identity "$scratch_fd")" == "$scratch_executable_identity" ]] || \
  fail "Scratch executable changed after copy"
[[ "$(path_directory_identity "$output_root/$app")" == "$app_identity" ]] || \
  fail "Public app entry changed during build"
[[ "$(path_directory_identity "$output_root/$app/Contents")" == "$contents_identity" ]] || \
  fail "Public Contents changed during build"

/usr/bin/codesign --force --deep --sign - .
[[ "$(directory_descriptor_identity "$app_fd")" == "$app_identity" ]] || \
  fail "Pinned app changed during signing"
assert_directory_entries "$app_fd" "Contents"
assert_directory_entries "$contents_fd" $'Info.plist\nMacOS\nResources\n_CodeSignature'
assert_directory_entries "$macos_fd" "PickVia"
assert_directory_entries "$resources_fd" $'PickVia.icns\nPickViaMenuBarTemplate.png'
[[ "$(path_directory_identity "$output_root/$app")" == "$app_identity" ]] || \
  fail "Public app entry changed after signing"
[[ "$(path_directory_identity "$output_root/$app/Contents")" == "$contents_identity" ]] || \
  fail "Public Contents changed after signing"

exec {resources_fd}>&-
exec {macos_fd}>&-
exec {contents_fd}>&-
exec {app_fd}>&-
exec {scratch_fd}>&-
scratch_fd=""

print -r -- "$output_root/$app"
