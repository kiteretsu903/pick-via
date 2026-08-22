#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$repo_root/.build-e2e"
app="$repo_root/build-e2e/PickVia E2E.app"
contents="$app/Contents"
resources="$contents/Resources"
app_icon="$repo_root/Support/Icons/PickVia.icns"
menu_icon="$repo_root/Support/Icons/PickViaMenuBarTemplate.png"

test "$scratch" = "$repo_root/.build-e2e"
test "$app" = "$repo_root/build-e2e/PickVia E2E.app"
test -s "$app_icon"
test -s "$menu_icon"

cd "$repo_root"
swift build -c release \
  --scratch-path "$scratch" \
  -Xswiftc -DPICKVIA_E2E_AUTOMATION \
  -Xswiftc -warnings-as-errors

test -x "$scratch/release/PickVia"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$resources"
cp "$scratch/release/PickVia" "$contents/MacOS/PickVia"
cp "$repo_root/Support/Info.plist" "$contents/Info.plist"
cp "$app_icon" "$resources/PickVia.icns"
cp "$menu_icon" "$resources/PickViaMenuBarTemplate.png"
chmod +x "$contents/MacOS/PickVia"

/usr/libexec/PlistBuddy -c \
  "Set :CFBundleIdentifier dev.bozhenpeng.PickVia.E2E" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName PickVia E2E" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PickViaE2EAutomation bool true" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Add :PickViaE2EAutomationMarker string PICKVIA_E2E_AUTOMATION_ENABLED" \
  "$contents/Info.plist"

/usr/bin/codesign --force --deep --sign - "$app"

print -r -- "$app"
