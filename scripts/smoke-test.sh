#!/bin/zsh
set -euo pipefail

app="${1:-build/PickVia.app}"
plist="$app/Contents/Info.plist"
executable="$app/Contents/MacOS/PickVia"

test -x "$executable"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "dev.bozhenpeng.PickVia"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" = "14.0"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$plist")" = "true"

schemes=("${(@f)$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes' "$plist" | sed -e '1d' -e '$d' -e 's/^[[:space:]]*//')}" )
test "${#schemes[@]}" -eq 2
test "${schemes[1]}" = "http"
test "${schemes[2]}" = "https"

/usr/bin/codesign --verify --deep --strict "$app"
