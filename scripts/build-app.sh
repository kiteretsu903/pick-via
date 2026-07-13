#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$repo_root/build/PickVia.app"
contents="$app/Contents"

cd "$repo_root"
swift build -c release

rm -rf "$app"
mkdir -p "$contents/MacOS"
cp "$repo_root/.build/release/PickVia" "$contents/MacOS/PickVia"
cp "$repo_root/Support/Info.plist" "$contents/Info.plist"
chmod +x "$contents/MacOS/PickVia"
/usr/bin/codesign --force --deep --sign - "$app"

print -r -- "$app"
