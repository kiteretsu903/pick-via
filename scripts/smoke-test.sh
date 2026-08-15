#!/bin/zsh
set -euo pipefail

app="${1:-build/PickVia.app}"
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/PickVia"

test -x "$executable"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "dev.bozhenpeng.PickVia"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" = "14.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist")" = "true"

test "$(plutil -extract CFBundleURLTypes raw -o - "$plist")" -eq 2
test "$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes raw -o - "$plist")" -eq 2
scheme0="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$plist")"
scheme1="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.1 raw -o - "$plist")"
test "$scheme0:$scheme1" = "http:https" || test "$scheme0:$scheme1" = "https:http"
test "$(plutil -extract CFBundleURLTypes.1.CFBundleURLSchemes raw -o - "$plist")" -eq 1
test "$(plutil -extract CFBundleURLTypes.1.CFBundleURLSchemes.0 raw -o - "$plist")" = "mailto"

resources="$app/Contents/Resources"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")" = "PickVia"
test -s "$resources/PickVia.icns"
test -s "$resources/PickViaMenuBarTemplate.png"
test "$(sips -g pixelWidth "$resources/PickViaMenuBarTemplate.png" | awk '/pixelWidth/ {print $2}')" = "44"
test "$(sips -g pixelHeight "$resources/PickViaMenuBarTemplate.png" | awk '/pixelHeight/ {print $2}')" = "44"

/usr/bin/codesign --verify --deep --strict "$app"
