#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
inspector=${1:-"$REPO_ROOT/scripts/browser-e2e/inspect-browser-app.sh"}

fixture_root=$(mktemp -d /private/tmp/pickvia-inspector-contract.XXXXXX)
cleanup() {
    case "$fixture_root" in
        /private/tmp/pickvia-inspector-contract.*) rm -rf -- "$fixture_root" ;;
        *) printf 'FAIL: refusing to clean unexpected fixture root: %s\n' "$fixture_root" >&2 ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

make_plist() {
    app=$1
    executable=$2
    mkdir -p "$app/Contents/MacOS"
    plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string dev.pickvia.InspectorFixture' "$plist" >/dev/null
    /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Inspector Fixture' "$plist" >/dev/null
    /usr/libexec/PlistBuddy -c 'Add :CFBundleName string Inspector Fixture' "$plist" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $executable" "$plist" >/dev/null
    /usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 1.0' "$plist" >/dev/null
}

expect_rejection() {
    label=$1
    expected=$2
    path=$3
    set +e
    output=$("$inspector" "$path" 2>&1)
    result=$?
    set -e
    if [[ $result -eq 0 ]]; then
        fail "$label unexpectedly succeeded"
    fi
    if [[ "$output" != *"$expected"* ]]; then
        printf 'FAIL: %s did not report %q\n' "$label" "$expected" >&2
        printf '%s\n' "$output" >&2
        exit 1
    fi
}

if [[ -d /System/Applications/Safari.app ]]; then
    known_good_app=/System/Applications/Safari.app
elif [[ -d /System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app ]]; then
    known_good_app=/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app
elif [[ -n ${KNOWN_GOOD_APP:-} && -d ${KNOWN_GOOD_APP:-} ]]; then
    known_good_app=$KNOWN_GOOD_APP
else
    fail 'no system Safari is available; set KNOWN_GOOD_APP to an explicit safe fixture'
fi

non_app="$fixture_root/InspectorFixture"
printf '#!/bin/sh\nexit 0\n' > "$non_app"
chmod +x "$non_app"
expect_rejection 'non-app' 'path must be an existing .app bundle' "$non_app"

missing_app="$fixture_root/MissingExecutable.app"
make_plist "$missing_app" MissingExecutable
expect_rejection 'missing executable' 'declared executable is missing or not executable' "$missing_app"

non_arm_app="$fixture_root/NonArm.app"
make_plist "$non_arm_app" NonArm
printf 'int main(void) { return 0; }\n' > "$fixture_root/non-arm.c"
xcrun clang -arch x86_64 "$fixture_root/non-arm.c" -o "$non_arm_app/Contents/MacOS/NonArm"
expect_rejection 'non-arm64 Mach-O' 'executable does not include arm64 architecture' "$non_arm_app"

unsigned_app="$fixture_root/Unsigned.app"
make_plist "$unsigned_app" Unsigned
printf 'int main(void) { return 0; }\n' > "$fixture_root/unsigned.c"
xcrun clang -arch arm64 "$fixture_root/unsigned.c" -o "$unsigned_app/Contents/MacOS/Unsigned"
expect_rejection 'unsigned arm64 bundle' 'bundle is not validly signed' "$unsigned_app"

tab_app="$fixture_root/Safari"$'\t'"Fixture.app"
del_app="$fixture_root/Safari"$'\177'"Fixture.app"
ln -s "$known_good_app" "$tab_app"
ln -s "$known_good_app" "$del_app"
expect_rejection 'tab control in emitted path' 'path contains a control character' "$tab_app"
expect_rejection 'DEL control in emitted path' 'path contains a control character' "$del_app"

success_output=$("$inspector" "$known_good_app")
expected_keys='path bundle_id display_name executable version architectures team_id authorities sha256'
actual_keys=$(printf '%s\n' "$success_output" | /usr/bin/sed 's/=.*//' | /usr/bin/paste -sd' ' -)
line_count=$(printf '%s\n' "$success_output" | /usr/bin/awk 'END { print NR }')
if [[ $line_count -ne 9 ]]; then
    fail "success output contained $line_count lines instead of 9"
fi
if [[ "$actual_keys" != "$expected_keys" ]]; then
    fail "success keys were '$actual_keys'"
fi
while IFS= read -r line; do
    if [[ "$line" != *=?* ]]; then
        fail "success output contained an empty value: $line"
    fi
    if LC_ALL=C /usr/bin/grep -q '[[:cntrl:]]' <<< "$line"; then
        fail 'success output contained a control character'
    fi
done <<< "$success_output"

printf 'PASS: inspector contract\n'
