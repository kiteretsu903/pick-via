#!/bin/bash

set -euo pipefail

fail() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

require_one_line() {
    case "$2" in
        *$'\n'*|*$'\r'*) fail "$1 contains a control character" ;;
    esac
    if LC_ALL=C /usr/bin/grep -q '[[:cntrl:]]' <<< "$2"; then
        fail "$1 contains a control character"
    fi
}

if [[ $# -ne 1 ]]; then
    printf 'usage: %s /path/to/Browser.app\n' "$0" >&2
    exit 64
fi

app_path=$1
if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
    fail 'path must be an existing .app bundle'
fi

info_plist="$app_path/Contents/Info.plist"
if [[ ! -f "$info_plist" ]]; then
    fail 'bundle is missing Contents/Info.plist'
fi

bundle_id=$(plist_value "$info_plist" CFBundleIdentifier)
if [[ -z "$bundle_id" ]]; then
    fail 'bundle is missing CFBundleIdentifier'
fi

display_name=$(plist_value "$info_plist" CFBundleDisplayName)
if [[ -z "$display_name" ]]; then
    display_name=$(plist_value "$info_plist" CFBundleName)
fi
if [[ -z "$display_name" ]]; then
    display_name=${app_path##*/}
    display_name=${display_name%.app}
fi

executable=$(plist_value "$info_plist" CFBundleExecutable)
if [[ -z "$executable" || "$executable" == */* || "$executable" == . || "$executable" == .. ]]; then
    fail 'declared executable is missing or not executable'
fi

executable_path="$app_path/Contents/MacOS/$executable"
if [[ ! -f "$executable_path" || ! -x "$executable_path" ]]; then
    fail 'declared executable is missing or not executable'
fi

version=$(plist_value "$info_plist" CFBundleShortVersionString)
if [[ -z "$version" ]]; then
    version=$(plist_value "$info_plist" CFBundleVersion)
fi
if [[ -z "$version" ]]; then
    fail 'bundle is missing a version'
fi

file_description=$(/usr/bin/file -b "$executable_path")
architectures=$(printf '%s\n' "$file_description" \
    | /usr/bin/grep -Eo 'x86_64|arm64e?|i386' \
    | /usr/bin/awk '!seen[$0]++' \
    | /usr/bin/paste -sd, - \
    || true)
if [[ ",$architectures," != *,arm64,* && ",$architectures," != *,arm64e,* ]]; then
    fail 'executable does not include arm64 architecture'
fi

if ! /usr/bin/codesign --verify --deep --strict "$app_path" >/dev/null 2>&1; then
    fail 'bundle is not validly signed'
fi

if ! signing_details=$(/usr/bin/codesign -dvvv "$app_path" 2>&1); then
    fail 'bundle is not validly signed'
fi

authorities=$(printf '%s\n' "$signing_details" \
    | /usr/bin/sed -n 's/^Authority=//p' \
    | /usr/bin/awk 'BEGIN { separator = "" } { printf "%s%s", separator, $0; separator = " | " } END { print "" }')
if [[ -z "$authorities" || "$signing_details" == *'Signature=adhoc'* ]]; then
    fail 'bundle is not validly signed'
fi

team_id=$(printf '%s\n' "$signing_details" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)
if [[ -z "$team_id" ]]; then
    team_id='not set'
fi

if ! /usr/sbin/spctl --assess --type execute "$app_path" >/dev/null 2>&1; then
    fail 'bundle failed Gatekeeper assessment'
fi

sha256=$(/usr/bin/shasum -a 256 "$executable_path" | /usr/bin/awk '{ print $1 }')

resolved_parent=$(cd "$(dirname "$app_path")" && pwd -P)
resolved_path="$resolved_parent/$(basename "$app_path")"

require_one_line path "$resolved_path"
require_one_line bundle_id "$bundle_id"
require_one_line display_name "$display_name"
require_one_line executable "$executable"
require_one_line version "$version"
require_one_line architectures "$architectures"
require_one_line team_id "$team_id"
require_one_line authorities "$authorities"
require_one_line sha256 "$sha256"

printf 'path=%s\n' "$resolved_path"
printf 'bundle_id=%s\n' "$bundle_id"
printf 'display_name=%s\n' "$display_name"
printf 'executable=%s\n' "$executable"
printf 'version=%s\n' "$version"
printf 'architectures=%s\n' "$architectures"
printf 'team_id=%s\n' "$team_id"
printf 'authorities=%s\n' "$authorities"
printf 'sha256=%s\n' "$sha256"
