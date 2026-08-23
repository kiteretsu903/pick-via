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
e2e_types=(
  PickVia.E2EChooserPresenter
  PickVia.E2EControl
  PickVia.E2EStatusWriter
  PickVia.E2EAutomationMarker
  PickVia.E2EEphemeralPreferences
)

contract_root="$(mktemp -d /private/tmp/pickvia-e2e-build-isolation.XXXXXX)"
case "$contract_root" in
  /private/tmp/pickvia-e2e-build-isolation.*) ;;
  *)
    print -u2 -r -- "Unsafe contract root: $contract_root"
    exit 1
    ;;
esac

cleanup() {
  rm -rf -- "$contract_root"
}
trap cleanup EXIT HUP INT TERM

binary_contains() {
  local binary="$1"
  local needle="$2"
  grep -Fq "$needle" < <(strings "$binary")
}

assert_symlinked_root_is_rejected_before_swift() {
  local case_name="$1"
  local unsafe_root="$2"
  local fixture="$contract_root/$case_name/repo"
  local external="$contract_root/$case_name/external"
  local fake_bin="$contract_root/$case_name/bin"
  local sentinel

  mkdir -p "$fixture/scripts" "$fixture/Support/Icons" "$fake_bin"
  cp "$repo_root/scripts/build-e2e-app.sh" "$fixture/scripts/build-e2e-app.sh"
  print -n -r -- "icon" > "$fixture/Support/Icons/PickVia.icns"
  print -n -r -- "menu" > "$fixture/Support/Icons/PickViaMenuBarTemplate.png"

  if [[ "$unsafe_root" == "scratch" ]]; then
    mkdir -p "$fixture/.build" "$fixture/build-e2e"
    sentinel="$fixture/.build/preserve-sentinel"
    ln -s "$fixture/.build" "$fixture/.build-e2e"
  else
    mkdir -p "$fixture/.build-e2e" "$external"
    sentinel="$external/preserve-sentinel"
    ln -s "$external" "$fixture/build-e2e"
  fi
  print -n -r -- "preserved" > "$sentinel"

  {
    print -r -- '#!/bin/zsh'
    print -r -- 'print -n -r -- "mutated" > "$PICKVIA_BUILD_CONTRACT_SENTINEL"'
    print -r -- 'exit 86'
  } > "$fake_bin/swift"
  chmod +x "$fake_bin/swift"

  if PICKVIA_BUILD_CONTRACT_SENTINEL="$sentinel" \
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    zsh "$fixture/scripts/build-e2e-app.sh" >/dev/null 2>&1
  then
    print -u2 -r -- "Unsafe $unsafe_root symlink was accepted"
    cleanup
    return 1
  fi

  if [[ "$(<"$sentinel")" != "preserved" ]]; then
    print -u2 -r -- "Unsafe $unsafe_root symlink reached Swift before rejection"
    cleanup
    return 1
  fi
}

assert_symlinked_root_is_rejected_before_swift scratch-symlink scratch
assert_symlinked_root_is_rejected_before_swift output-symlink output

assert_output_swap_at_removal_preserves_replacement() {
  local fixture="$contract_root/output-operation-swap/repo"
  local hook="$contract_root/output-operation-swap/hook"
  local swap_marker="$contract_root/output-operation-swap/swap-ran"
  local replacement_sentinel

  mkdir -p \
    "$fixture/scripts" \
    "$fixture/Support/Icons" \
    "$fixture/.build-e2e/release" \
    "$fixture/build-e2e/PickVia E2E.app"
  cp "$repo_root/scripts/build-e2e-app.sh" "$fixture/scripts/build-e2e-app.sh"
  cp "$repo_root/Support/Info.plist" "$fixture/Support/Info.plist"
  print -n -r -- "icon" > "$fixture/Support/Icons/PickVia.icns"
  print -n -r -- "menu" > "$fixture/Support/Icons/PickViaMenuBarTemplate.png"
  {
    print -r -- '#!/bin/zsh'
    print -r -- 'fixture="$PICKVIA_BUILD_CONTRACT_FIXTURE"'
    print -r -- 'case "$1" in'
    print -r -- '  build)'
    print -r -- '    /bin/mkdir -p "$fixture/.build-e2e/release"'
    print -r -- '    /bin/cp /usr/bin/true "$fixture/.build-e2e/release/PickVia"'
    print -r -- '    ;;'
    print -r -- '  before-app-entry-open)'
    print -r -- '    /bin/mv "$fixture/build-e2e" "$fixture/build-e2e-held"'
    print -r -- '    /bin/mkdir -p "$fixture/build-e2e/PickVia E2E.app"'
    print -r -- '    print -n -r -- "replacement" > "$fixture/build-e2e/PickVia E2E.app/replacement-must-survive"'
    print -r -- '    print -n -r -- "swapped" > "$PICKVIA_BUILD_CONTRACT_SWAP_MARKER"'
    print -r -- '    ;;'
    print -r -- 'esac'
  } > "$hook"
  chmod +x "$hook"

  replacement_sentinel="$fixture/build-e2e/PickVia E2E.app/replacement-must-survive"
  if PICKVIA_BUILD_CONTRACT_FIXTURE="$fixture" \
    PICKVIA_BUILD_CONTRACT_SWAP_MARKER="$swap_marker" \
    PICKVIA_BUILD_E2E_CONTRACT_HOOK="$hook" \
    zsh "$fixture/scripts/build-e2e-app.sh" >/dev/null 2>&1
  then
    print -u2 -r -- "Operation-time output replacement was accepted"
    return 1
  fi

  test -f "$swap_marker"
  test -f "$replacement_sentinel"
  test "$(<"$replacement_sentinel")" = "replacement"
  test -z "$(find "$fixture/build-e2e/PickVia E2E.app" -mindepth 1 \
    ! -name replacement-must-survive -print -quit)"
}

assert_output_swap_at_removal_preserves_replacement

assert_scratch_swap_before_copy_fails_closed() {
  local fixture="$contract_root/scratch-operation-swap/repo"
  local hook="$contract_root/scratch-operation-swap/hook"
  local replacement="$fixture/.build-e2e/release/PickVia"

  mkdir -p "$fixture/scripts" "$fixture/Support/Icons" "$fixture/.build-e2e" \
    "$fixture/build-e2e"
  cp "$repo_root/scripts/build-e2e-app.sh" "$fixture/scripts/build-e2e-app.sh"
  cp "$repo_root/Support/Info.plist" "$fixture/Support/Info.plist"
  print -n -r -- "icon" > "$fixture/Support/Icons/PickVia.icns"
  print -n -r -- "menu" > "$fixture/Support/Icons/PickViaMenuBarTemplate.png"
  {
    print -r -- '#!/bin/zsh'
    print -r -- 'fixture="$PICKVIA_BUILD_CONTRACT_FIXTURE"'
    print -r -- 'case "$1" in'
    print -r -- '  build)'
    print -r -- '    /bin/mkdir -p "$fixture/.build-e2e/release"'
    print -r -- '    /bin/cp /usr/bin/true "$fixture/.build-e2e/release/PickVia"'
    print -r -- '    ;;'
    print -r -- '  before-scratch-copy)'
    print -r -- '    /bin/mv "$fixture/.build-e2e" "$fixture/.build-e2e-held"'
    print -r -- '    /bin/mkdir -p "$fixture/.build-e2e/release"'
    print -r -- '    print -n -r -- "replacement" > "$fixture/.build-e2e/release/PickVia"'
    print -r -- '    /bin/chmod 700 "$fixture/.build-e2e/release/PickVia"'
    print -r -- '    ;;'
    print -r -- 'esac'
  } > "$hook"
  chmod +x "$hook"

  if PICKVIA_BUILD_CONTRACT_FIXTURE="$fixture" \
    PICKVIA_BUILD_E2E_CONTRACT_HOOK="$hook" \
    zsh "$fixture/scripts/build-e2e-app.sh" >/dev/null 2>&1
  then
    print -u2 -r -- "Operation-time scratch replacement was accepted"
    return 1
  fi

  test -f "$replacement"
  test "$(<"$replacement")" = "replacement"
  test ! -e "$fixture/build-e2e/PickVia E2E.app/Contents/MacOS/PickVia"
}

assert_scratch_swap_before_copy_fails_closed

assert_same_size_scratch_mutation_before_copy_fails_closed() {
  local fixture="$contract_root/scratch-content-mutation/repo"
  local hook="$contract_root/scratch-content-mutation/hook"

  mkdir -p "$fixture/scripts" "$fixture/Support/Icons" "$fixture/.build-e2e" \
    "$fixture/build-e2e"
  cp "$repo_root/scripts/build-e2e-app.sh" "$fixture/scripts/build-e2e-app.sh"
  cp "$repo_root/Support/Info.plist" "$fixture/Support/Info.plist"
  print -n -r -- "icon" > "$fixture/Support/Icons/PickVia.icns"
  print -n -r -- "menu" > "$fixture/Support/Icons/PickViaMenuBarTemplate.png"
  {
    print -r -- '#!/bin/zsh'
    print -r -- 'fixture="$PICKVIA_BUILD_CONTRACT_FIXTURE"'
    print -r -- 'case "$1" in'
    print -r -- '  build)'
    print -r -- '    /bin/mkdir -p "$fixture/.build-e2e/release"'
    print -r -- '    /bin/cp /usr/bin/true "$fixture/.build-e2e/release/PickVia"'
    print -r -- '    ;;'
    print -r -- '  before-scratch-copy)'
    print -r -- '    size=$(/usr/bin/stat -f %z "$fixture/.build-e2e/release/PickVia")'
    print -r -- '    /bin/dd if=/dev/zero of="$fixture/.build-e2e/release/PickVia" bs="$size" count=1 conv=notrunc >/dev/null 2>&1'
    print -r -- '    ;;'
    print -r -- 'esac'
  } > "$hook"
  chmod +x "$hook"

  if PICKVIA_BUILD_CONTRACT_FIXTURE="$fixture" \
    PICKVIA_BUILD_E2E_CONTRACT_HOOK="$hook" \
    zsh "$fixture/scripts/build-e2e-app.sh" >/dev/null 2>&1
  then
    print -u2 -r -- "Same-size scratch mutation was accepted"
    return 1
  fi
  test ! -e "$fixture/build-e2e/PickVia E2E.app/Contents/MacOS/PickVia"
}

assert_same_size_scratch_mutation_before_copy_fails_closed

assert_concurrent_publish_entry_is_preserved() {
  local fixture="$contract_root/concurrent-publish/repo"
  local hook="$contract_root/concurrent-publish/hook"
  local sentinel="$fixture/build-e2e/PickVia E2E.app/concurrent-must-survive"

  mkdir -p "$fixture/scripts" "$fixture/Support/Icons" "$fixture/.build-e2e" \
    "$fixture/build-e2e"
  cp "$repo_root/scripts/build-e2e-app.sh" "$fixture/scripts/build-e2e-app.sh"
  cp "$repo_root/Support/Info.plist" "$fixture/Support/Info.plist"
  cp "$repo_root/Support/Icons/PickVia.icns" "$fixture/Support/Icons/PickVia.icns"
  cp "$repo_root/Support/Icons/PickViaMenuBarTemplate.png" \
    "$fixture/Support/Icons/PickViaMenuBarTemplate.png"
  {
    print -r -- '#!/bin/zsh'
    print -r -- 'fixture="$PICKVIA_BUILD_CONTRACT_FIXTURE"'
    print -r -- 'case "$1" in'
    print -r -- '  build)'
    print -r -- '    /bin/mkdir -p "$fixture/.build-e2e/release"'
    print -r -- '    /bin/cp /usr/bin/true "$fixture/.build-e2e/release/PickVia"'
    print -r -- '    ;;'
    print -r -- '  before-app-reservation)'
    print -r -- '    /bin/mkdir -p "$fixture/build-e2e/PickVia E2E.app"'
    print -r -- '    print -n -r -- "concurrent" > "$fixture/build-e2e/PickVia E2E.app/concurrent-must-survive"'
    print -r -- '    ;;'
    print -r -- 'esac'
  } > "$hook"
  chmod +x "$hook"

  if PICKVIA_BUILD_CONTRACT_FIXTURE="$fixture" \
    PICKVIA_BUILD_E2E_CONTRACT_HOOK="$hook" \
    zsh "$fixture/scripts/build-e2e-app.sh" >/dev/null 2>&1
  then
    print -u2 -r -- "Concurrent publish entry was overwritten"
    return 1
  fi

  test -f "$sentinel"
  test "$(<"$sentinel")" = "concurrent"
  test -z "$(find "$fixture/build-e2e/PickVia E2E.app" -mindepth 1 \
    ! -name concurrent-must-survive -print -quit)"
}

assert_concurrent_publish_entry_is_preserved

assert_app_entry_replacement_before_open_is_preserved() {
  local fixture="$contract_root/app-entry-swap/repo"
  local hook="$contract_root/app-entry-swap/hook"
  local sentinel="$fixture/build-e2e/PickVia E2E.app/replacement-must-survive"

  mkdir -p "$fixture/scripts" "$fixture/Support/Icons" "$fixture/.build-e2e" \
    "$fixture/build-e2e/PickVia E2E.app"
  cp "$repo_root/scripts/build-e2e-app.sh" "$fixture/scripts/build-e2e-app.sh"
  cp "$repo_root/Support/Info.plist" "$fixture/Support/Info.plist"
  cp "$repo_root/Support/Icons/PickVia.icns" "$fixture/Support/Icons/PickVia.icns"
  cp "$repo_root/Support/Icons/PickViaMenuBarTemplate.png" \
    "$fixture/Support/Icons/PickViaMenuBarTemplate.png"
  {
    print -r -- '#!/bin/zsh'
    print -r -- 'fixture="$PICKVIA_BUILD_CONTRACT_FIXTURE"'
    print -r -- 'case "$1" in'
    print -r -- '  build)'
    print -r -- '    /bin/mkdir -p "$fixture/.build-e2e/release"'
    print -r -- '    /bin/cp /usr/bin/true "$fixture/.build-e2e/release/PickVia"'
    print -r -- '    ;;'
    print -r -- '  before-app-entry-open)'
    print -r -- '    /bin/mv "$fixture/build-e2e/PickVia E2E.app" "$fixture/build-e2e/app-held"'
    print -r -- '    /bin/mkdir "$fixture/build-e2e/PickVia E2E.app"'
    print -r -- '    print -n -r -- "replacement" > "$fixture/build-e2e/PickVia E2E.app/replacement-must-survive"'
    print -r -- '    ;;'
    print -r -- 'esac'
  } > "$hook"
  chmod +x "$hook"

  if PICKVIA_BUILD_CONTRACT_FIXTURE="$fixture" \
    PICKVIA_BUILD_E2E_CONTRACT_HOOK="$hook" \
    zsh "$fixture/scripts/build-e2e-app.sh" >/dev/null 2>&1
  then
    print -u2 -r -- "App-entry replacement was accepted"
    return 1
  fi
  test -f "$sentinel"
  test "$(<"$sentinel")" = "replacement"
  test -z "$(find "$fixture/build-e2e/PickVia E2E.app" -mindepth 1 \
    ! -name replacement-must-survive -print -quit)"
}

assert_app_entry_replacement_before_open_is_preserved

assert_contents_symlink_before_open_is_rejected() {
  local fixture="$contract_root/contents-symlink-swap/repo"
  local hook="$contract_root/contents-symlink-swap/hook"
  local external="$contract_root/contents-symlink-swap/external"
  local sentinel="$external/must-survive"

  mkdir -p "$fixture/scripts" "$fixture/Support/Icons" "$fixture/.build-e2e" \
    "$fixture/build-e2e/PickVia E2E.app/Contents" "$external"
  cp "$repo_root/scripts/build-e2e-app.sh" "$fixture/scripts/build-e2e-app.sh"
  cp "$repo_root/Support/Info.plist" "$fixture/Support/Info.plist"
  cp "$repo_root/Support/Icons/PickVia.icns" "$fixture/Support/Icons/PickVia.icns"
  cp "$repo_root/Support/Icons/PickViaMenuBarTemplate.png" \
    "$fixture/Support/Icons/PickViaMenuBarTemplate.png"
  print -n -r -- "preserved" > "$sentinel"
  {
    print -r -- '#!/bin/zsh'
    print -r -- 'fixture="$PICKVIA_BUILD_CONTRACT_FIXTURE"'
    print -r -- 'external="$PICKVIA_BUILD_CONTRACT_EXTERNAL"'
    print -r -- 'case "$1" in'
    print -r -- '  build)'
    print -r -- '    /bin/mkdir -p "$fixture/.build-e2e/release"'
    print -r -- '    /bin/cp /usr/bin/true "$fixture/.build-e2e/release/PickVia"'
    print -r -- '    ;;'
    print -r -- '  before-contents-open)'
    print -r -- '    /bin/mv "$fixture/build-e2e/PickVia E2E.app/Contents" "$fixture/build-e2e/Contents-held"'
    print -r -- '    /bin/ln -s "$external" "$fixture/build-e2e/PickVia E2E.app/Contents"'
    print -r -- '    ;;'
    print -r -- 'esac'
  } > "$hook"
  chmod +x "$hook"

  if PICKVIA_BUILD_CONTRACT_FIXTURE="$fixture" \
    PICKVIA_BUILD_CONTRACT_EXTERNAL="$external" \
    PICKVIA_BUILD_E2E_CONTRACT_HOOK="$hook" \
    zsh "$fixture/scripts/build-e2e-app.sh" >/dev/null 2>&1
  then
    print -u2 -r -- "Contents symlink replacement was accepted"
    return 1
  fi
  test -f "$sentinel"
  test "$(<"$sentinel")" = "preserved"
  test -z "$(find "$external" -mindepth 1 ! -name must-survive -print -quit)"
}

assert_contents_symlink_before_open_is_rejected

assert_smoke_contract_is_status_driven_and_browser_free() {
  local smoke="$repo_root/scripts/smoke-test-e2e.sh"
  local policy="$repo_root/scripts/browser-e2e/smoke_e2e_runtime.py"

  grep -Fq "dev.bozhenpeng.PickVia.E2E.Missing||normal" "$smoke"
  grep -Fq '"outcome":"target-missing"' "$smoke"
  grep -Fq 'read -r -t ' "$smoke"
  grep -Fq 'kill -KILL' "$smoke"
  grep -Fq 'compile-helper' "$smoke"
  grep -Fq 'run-helper' "$smoke"
  grep -Fq '"Library" / "Preferences"' "$policy"
  grep -Fq '"ByHost"' "$policy"
  grep -Fq 'os.O_NOFOLLOW' "$policy"
  ! grep -Fq "com.microsoft.edgemac||normal" "$smoke"
  ! grep -Fq "sleep 0.25" "$smoke"
}

assert_smoke_contract_is_status_driven_and_browser_free

/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=en_US.UTF-8 \
  LC_CTYPE=UTF-8 \
  PYTHONDONTWRITEBYTECODE=1 \
  /usr/bin/python3 "$repo_root/scripts/browser-e2e/test_smoke_e2e_runtime.py" >/dev/null

zsh "$repo_root/scripts/build-app.sh" >/dev/null
zsh "$repo_root/scripts/build-e2e-app.sh" >/dev/null

signature_fixture="$contract_root/signature-mutation/PickVia E2E.app"
mkdir -p "${signature_fixture:h}"
cp -R "$e2e_app" "$signature_fixture"
/usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=en_US.UTF-8 \
  LC_CTYPE=UTF-8 \
  PYTHONDONTWRITEBYTECODE=1 \
  /usr/bin/python3 "$repo_root/scripts/browser-e2e/smoke_e2e_runtime.py" \
    verify-app "$signature_fixture"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Mutated' \
  "$signature_fixture/Contents/Info.plist"
if /usr/bin/env -i \
  PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  LANG=en_US.UTF-8 \
  LC_CTYPE=UTF-8 \
  PYTHONDONTWRITEBYTECODE=1 \
  /usr/bin/python3 "$repo_root/scripts/browser-e2e/smoke_e2e_runtime.py" \
    verify-app "$signature_fixture"
then
  print -u2 -r -- "Mutated signed bundle was accepted"
  exit 1
fi

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

normal_symbols="$contract_root/normal-symbols.txt"
e2e_symbols="$contract_root/e2e-symbols.txt"
nm -a "$normal_executable" 2>/dev/null | xcrun swift-demangle > "$normal_symbols"
nm -a "$e2e_executable" 2>/dev/null | xcrun swift-demangle > "$e2e_symbols"

for type_name in "${e2e_types[@]}"; do
  ! grep -Fq "$type_name" "$normal_symbols"
  grep -Fq "$type_name" "$e2e_symbols"
done
