#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app="$repo_root/build/PickVia.app"
contents="$app/Contents"
resources="$contents/Resources"
app_icon="$repo_root/Support/Icons/PickVia.icns"
menu_icon="$repo_root/Support/Icons/PickViaMenuBarTemplate.png"

# Pin a local certificate fingerprint; never silently fall back to ad-hoc signing.
identity_file="$repo_root/.signing-identity"
signing_identity="${PICKVIA_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" && -f "$identity_file" ]]; then
  signing_identity="$(<"$identity_file")"
fi
if [[ -z "$signing_identity" ]]; then
  print -u2 "Set PICKVIA_SIGNING_IDENTITY or create .signing-identity with your codesigning certificate SHA-1."
  exit 1
fi
cd "$repo_root"
python3 scripts/generate-app-localizations.py
swift build -c release

test -s "$app_icon"
test -s "$menu_icon"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$resources"
cp "$repo_root/.build/release/PickVia" "$contents/MacOS/PickVia"
cp "$repo_root/Support/Info.plist" "$contents/Info.plist"
cp "$app_icon" "$resources/PickVia.icns"
cp "$menu_icon" "$resources/PickViaMenuBarTemplate.png"
python3 scripts/embed-app-localizations.py "$app" "$repo_root/.build/release/PickVia_PickViaCore.bundle"
chmod +x "$contents/MacOS/PickVia"
/usr/bin/codesign --force --sign "$signing_identity" "$app"

print -r -- "$app"
