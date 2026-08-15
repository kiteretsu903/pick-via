#!/bin/zsh

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$repo_root/build/PickVia.app}"
background="$repo_root/Support/DMG/dmg-background.png"
icon="$repo_root/Support/Icons/PickVia.icns"
create_dmg="${CREATE_DMG:-$(command -v create-dmg || true)}"

if [[ ! -d "$app" ]]; then
  print -u2 -- "Missing $app; run zsh scripts/build-app.sh first."
  exit 1
fi

if [[ ! -x "$create_dmg" ]]; then
  print -u2 -- "create-dmg is required. Install it with: brew install create-dmg"
  exit 1
fi

if [[ ! -f "$background" ]]; then
  print -u2 -- "Missing $background; run swift scripts/render-dmg-background.swift first."
  exit 1
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
output="${2:-$repo_root/dist/PickVia-v${version}.dmg}"
work="$(mktemp -d /private/tmp/pickvia-dmg.XXXXXX)"
stage="$work/stage"

cleanup() {
  if [[ "$work" == /private/tmp/pickvia-dmg.* ]]; then
    rm -rf "$work"
  fi
}
trap cleanup EXIT

mkdir -p "$stage" "${output:h}"
cp -R "$app" "$stage/PickVia.app"

"$create_dmg" \
  --overwrite \
  --volname "Install PickVia" \
  --volicon "$icon" \
  --background "$background" \
  --window-pos 120 120 \
  --window-size 660 400 \
  --text-size 13 \
  --icon-size 96 \
  --icon "PickVia.app" 170 210 \
  --hide-extension "PickVia.app" \
  --app-drop-link 490 210 \
  --no-internet-enable \
  --applescript-sleep-duration 10 \
  "$output" "$stage"

hdiutil verify "$output"
print -r -- "$output"
