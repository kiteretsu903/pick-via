#!/bin/zsh
set -euo pipefail

app="${1:-build/PickVia.app}"
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/PickVia"

test -x "$executable"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "dev.bozhenpeng.PickVia"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" = "14.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist")" = "true"

test "$(plutil -extract CFBundleURLTypes raw -o - "$plist")" -eq 1
test "$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes raw -o - "$plist")" -eq 2
scheme0="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw -o - "$plist")"
scheme1="$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.1 raw -o - "$plist")"
test "$scheme0:$scheme1" = "http:https" || test "$scheme0:$scheme1" = "https:http"

/usr/bin/codesign --verify --deep --strict "$app"
