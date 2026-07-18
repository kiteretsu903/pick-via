#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$repo_root/build/PickVia.app"
contents="$app/Contents"
resources="$contents/Resources"
app_icon="$repo_root/Support/Icons/PickVia.icns"
menu_icon="$repo_root/Support/Icons/PickViaMenuBarTemplate.png"

cd "$repo_root"
swift build -c release

test -s "$app_icon"
test -s "$menu_icon"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$resources"
cp "$repo_root/.build/release/PickVia" "$contents/MacOS/PickVia"
cp "$repo_root/Support/Info.plist" "$contents/Info.plist"
cp "$app_icon" "$resources/PickVia.icns"
cp "$menu_icon" "$resources/PickViaMenuBarTemplate.png"
chmod +x "$contents/MacOS/PickVia"
/usr/bin/codesign --force --deep --sign - "$app"

print -r -- "$app"
