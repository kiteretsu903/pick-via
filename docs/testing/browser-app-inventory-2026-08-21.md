# Browser application inventory — 2026-08-21

Status: `DONE_WITH_CONCERNS` — complete with one blocked matrix row

Sixteen missing browser applications were downloaded from first-party sources, staged, inspected, installed side by side under their official distinct names, and re-inspected. Each installed identity and executable SHA-256 matched its staged source exactly. The official Chromium arm64 snapshot is the sole blocked row: it is ad-hoc/linker-signed, fails strict code-signature verification, and fails Gatekeeper assessment, so it was not installed.

No browser was launched. No browser profile root or profile content was traversed. No existing application was overwritten. No default-browser setting, account, profile, bundled offer, or `/Applications/PickVia.app` state was changed.

## Inspector contract

The inspector is `scripts/browser-e2e/inspect-browser-app.sh`.

The original chronological test driver was the fixed, non-unique path `/private/tmp/pickvia-inspector-contract.sh`; each invocation created its fixtures under a unique `mktemp -d /private/tmp/pickvia-inspector-contract.XXXXXX` directory and removed that fixture directory on exit. The chronological transcript was:

1. Before the production script existed, RED exited `1`:

   ```text
   FAIL: non-app did not report 'path must be an existing .app bundle'
   /private/tmp/pickvia-inspector-contract.sh: line 40: /Users/bozhenpeng/gitrepos/pick-via/.worktrees/browser-editions-and-families/scripts/browser-e2e/inspect-browser-app.sh: No such file or directory
   ```

2. The first implementation run also exited `1`; it exposed a pipeline-status bug in the assertion driver rather than a production pass:

   ```text
   FAIL: non-arm64 did not report 'executable does not include arm64 architecture'
   ```

3. After replacing that assertion pipeline with a shell string match, the unchanged four-case contract exited `0`:

   ```text
   PASS: inspector contract
   ```

That chronological temporary driver was deleted during the original cleanup. The following is a separate, post-hoc reproducibility run; it is not presented as the original RED/GREEN observation. It used the unique driver root `/private/tmp/pickvia-inspector-repro.Kx08YQ`, expanded base commit `80d499d` under `base/`, and verified that the base tree had no inspector. This is the exact assertion body used:

```bash
#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s /path/to/inspect-browser-app.sh\n' "$0" >&2
    exit 64
fi

inspector=$1
fixture_root=$(mktemp -d /private/tmp/pickvia-inspector-contract.XXXXXX)
trap 'rm -rf "$fixture_root"' EXIT

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

non_app="$fixture_root/InspectorFixture"
printf '#!/bin/sh\nexit 0\n' > "$non_app"
chmod +x "$non_app"
expect_rejection 'non-app' 'path must be an existing .app bundle' "$non_app"

missing_app="$fixture_root/MissingExecutable.app"
make_plist "$missing_app" MissingExecutable
expect_rejection 'missing executable' 'declared executable is missing or not executable' "$missing_app"

non_arm_app="$fixture_root/NonArm.app"
make_plist "$non_arm_app" NonArm
printf '#!/bin/sh\nexit 0\n' > "$non_arm_app/Contents/MacOS/NonArm"
chmod +x "$non_arm_app/Contents/MacOS/NonArm"
expect_rejection 'non-arm64' 'executable does not include arm64 architecture' "$non_arm_app"

unsigned_app="$fixture_root/Unsigned.app"
make_plist "$unsigned_app" Unsigned
printf 'int main(void) { return 0; }\n' > "$fixture_root/unsigned.c"
xcrun clang -arch arm64 "$fixture_root/unsigned.c" -o "$unsigned_app/Contents/MacOS/Unsigned"
expect_rejection 'unsigned bundle' 'bundle is not validly signed' "$unsigned_app"

known_good_app=${KNOWN_GOOD_APP:-/Applications/Rectangle.app}
success_output=$("$inspector" "$known_good_app")
expected_keys='path bundle_id display_name executable version architectures team_id authorities sha256'
actual_keys=$(printf '%s\n' "$success_output" | sed 's/=.*//' | paste -sd' ' -)
if [[ "$actual_keys" != "$expected_keys" ]]; then
    fail "success keys were '$actual_keys'"
fi
while IFS= read -r line; do
    if [[ "$line" != *=?* ]]; then
        fail "success output contained an empty value: $line"
    fi
done <<< "$success_output"

printf 'PASS: inspector contract\n'
```

The post-hoc commands and complete compact transcript were:

```bash
git archive 80d499d | tar -x -C /private/tmp/pickvia-inspector-repro.Kx08YQ/base
/private/tmp/pickvia-inspector-repro.Kx08YQ/contract.sh /private/tmp/pickvia-inspector-repro.Kx08YQ/base/scripts/browser-e2e/inspect-browser-app.sh
# exit 1
FAIL: non-app did not report path\ must\ be\ an\ existing\ .app\ bundle
/private/tmp/pickvia-inspector-repro.Kx08YQ/contract.sh: line 36: /private/tmp/pickvia-inspector-repro.Kx08YQ/base/scripts/browser-e2e/inspect-browser-app.sh: No such file or directory

KNOWN_GOOD_APP=/Applications/Rectangle.app /private/tmp/pickvia-inspector-repro.Kx08YQ/contract.sh /Users/bozhenpeng/gitrepos/pick-via/.worktrees/browser-editions-and-families/scripts/browser-e2e/inspect-browser-app.sh
# exit 0
PASS: inspector contract
```

The rejection cases are a non-`.app` path, a missing declared executable, an executable without arm64, and an unsigned bundle. Successful inspector output contains exactly these keys, in this order: `path`, `bundle_id`, `display_name`, `executable`, `version`, `architectures`, `team_id`, `authorities`, `sha256`. Read-only inspection uses `/usr/libexec/PlistBuddy`, `file`, `codesign -dvvv`, `codesign --verify --deep --strict`, `spctl --assess --type execute`, and `shasum -a 256`.

## First-party resolution sources

Only first-party product pages, feeds, update APIs, or vendor-controlled artifact endpoints were used.

| Vendor/family | First-party source |
| --- | --- |
| Safari Technology Preview | [Apple Developer Safari Resources](https://developer.apple.com/safari/resources/) |
| Chromium | [Chromium project download instructions](https://www.chromium.org/getting-involved/download-chromium/) and the official Chromium snapshot bucket |
| Google Chrome channels | [Chrome release channels](https://www.chromium.org/chrome-release-channels/), [Chrome Dev](https://www.google.com/chrome/dev/), and [Chrome Canary](https://www.google.com/chrome/canary/) |
| Microsoft Edge channels | [Microsoft Edge Insider](https://www.microsoft.com/en-us/edge/download/insider) and [Microsoft Edge update API](https://edgeupdates.microsoft.com/api/products) |
| Brave channels | [Brave Beta](https://brave.com/download-beta/) and [Brave Nightly](https://brave.com/download-nightly/) |
| Vivaldi channels | [Vivaldi download](https://vivaldi.com/download/), [desktop snapshot feed](https://vivaldi.com/blog/desktop/snapshots/feed/), and [official-build signature guidance](https://help.vivaldi.com/desktop/install-update/obtaining-official-builds/) |
| Firefox channels | [Mozilla Firefox channels](https://www.mozilla.org/firefox/channel/) and [Developer Edition](https://www.mozilla.org/en-US/firefox/developer/) |
| Opera | [Opera download](https://www.opera.com/download), including its first-party offline-package link |
| Arc | [Arc](https://arc.net/) and [Arc macOS support](https://resources.arc.net/hc/en-us/articles/19337669022103-Arc-for-macOS) |
| Orion | [Orion](https://orionbrowser.com/) and [Kagi installation documentation](https://help.kagi.com/orion/getting-started/installing-orion.html) |

## Download evidence

Retrieval time is the artifact modification time after `curl --fail --location` completed, recorded in UTC. SHA-256 values were computed locally with `shasum -a 256`.

| Application/artifact | Requested URL | Final URL | Retrieved UTC | Filename | Bytes | SHA-256 |
| --- | --- | --- | --- | --- | ---: | --- |
| Safari Technology Preview | `https://secure-appldnld.apple.com/STP/140-89042-20260813-ef259790-1d29-421a-8f8c-c943f6f44be0/SafariTechnologyPreview.dmg` | same | 2026-08-21T22:50:21Z | `SafariTechnologyPreview.dmg` | 220486209 | `15058eae5299b2da373f46eebf968c65bcaf126992ed7beb7a31c556bdb271a1` |
| Chromium snapshot 1684265 | `https://commondatastorage.googleapis.com/chromium-browser-snapshots/Mac_Arm/1684265/chrome-mac.zip` | same | 2026-08-21T22:50:37Z | `chromium-1684265-mac-arm.zip` | 172137082 | `dcff851fbb30bd4268e9b977b716134f4a7f6d4d660afd42b7a8faa9691803c5` |
| Google Chrome Dev | `https://dl.google.com/chrome/mac/universal/dev/googlechromedev.dmg` | same | 2026-08-21T22:50:41Z | `googlechromedev.dmg` | 273838705 | `5b47c2e1a95babfcded108f6b2ef9f5f0ef2bf7dce208be2af77dba9a6739518` |
| Google Chrome Canary | `https://dl.google.com/chrome/mac/universal/canary/googlechromecanary.dmg` | same | 2026-08-21T22:50:40Z | `googlechromecanary.dmg` | 270898905 | `1b646bfdab94c7951e3ccb500d645a57c4736d994fb95814471fdd12aa7183b5` |
| Microsoft Edge Stable | `https://edgeupdates.microsoft.com/api/products` (`Product=Stable`, latest `MacOS`/`universal`) | `https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/e289fa29-2cf4-4bbd-9a55-28098fe74455/MicrosoftEdge-151.0.4129.101.pkg` | 2026-08-21T22:50:37Z | `MicrosoftEdge-151.0.4129.101.pkg` | 430912543 | `1c65c6765e6810cb81c9969de230a740b896bca3cc0acab52999830060a80cf4` |
| Microsoft Edge Beta | `https://edgeupdates.microsoft.com/api/products` (`Product=Beta`, latest `MacOS`/`universal`) | `https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/8e762782-163f-4543-b3c6-8084423432a0/MicrosoftEdgeBeta-152.0.4191.41.pkg` | 2026-08-21T22:50:39Z | `MicrosoftEdgeBeta-152.0.4191.41.pkg` | 432035572 | `e56ee05b1a3e20759459038c431344d3acd596d6590f4d79929b3ed15f60663d` |
| Microsoft Edge Dev | `https://edgeupdates.microsoft.com/api/products` (`Product=Dev`, latest `MacOS`/`universal`) | `https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/f7b6e42d-a4fd-4f14-b226-4797ecec61a0/MicrosoftEdgeDev-153.0.4224.0.pkg` | 2026-08-21T22:51:13Z | `MicrosoftEdgeDev-153.0.4224.0.pkg` | 428487703 | `ce8c7164c60bc431d9a9c0bbb7aad38136d99d49152602bf5f1407ad2e43223f` |
| Microsoft Edge Canary | `https://edgeupdates.microsoft.com/api/products` (`Product=Canary`, latest `MacOS`/`universal`) | `https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/3595ffb4-017b-4067-9240-37b8c59da63f/MicrosoftEdgeCanary-153.0.4233.0.pkg` | 2026-08-21T22:51:19Z | `MicrosoftEdgeCanary-153.0.4233.0.pkg` | 431298600 | `965e4fac32bc533d90b07dee138285f7f84cf95a96bdebc4f4c4484e32210226` |
| Brave Beta | `https://laptop-updates.brave.com/latest/osx/beta` | `https://referrals.brave.com/latest/Brave-Browser-Beta.dmg` | 2026-08-21T22:50:58Z | `Brave-Browser-Beta.dmg` | 259496302 | `6cf2c205a153d477baf79506da3eaf6697cc0544b1f0f6797c096d601c92df33` |
| Brave Nightly | `https://laptop-updates.brave.com/latest/osx/nightly` | `https://referrals.brave.com/latest/Brave-Browser-Nightly.dmg` | 2026-08-21T22:51:00Z | `Brave-Browser-Nightly.dmg` | 262821127 | `d847d380f306f14524eda99f775048551487aaa69120a1ca9aed5976088686a0` |
| Vivaldi Stable | `https://downloads.vivaldi.com/stable/Vivaldi.8.1.4087.70.universal.dmg` | same | 2026-08-21T22:51:31Z | `Vivaldi.8.1.4087.70.universal.dmg` | 233959896 | `06ada90cbef764c71c7d899f9196342c954d57b21316051f86a5667d8d12597a` |
| Vivaldi Snapshot | `https://downloads.vivaldi.com/snapshot/Vivaldi.8.2.4133.24.universal.dmg` | same | 2026-08-21T22:51:32Z | `Vivaldi.8.2.4133.24.universal.dmg` | 240626545 | `5b0a7b4588073bb10951e544cbe245c89e7319520484d56ed9cd37e5c7ab4c56` |
| Firefox Developer Edition | `https://download.mozilla.org/?product=firefox-devedition-latest-ssl&os=osx&lang=en-US` | `https://download-installer.cdn.mozilla.net/pub/devedition/releases/155.0b3/mac/en-US/Firefox%20155.0b3.dmg` | 2026-08-21T22:51:58Z | `Firefox-Developer-155.0b3.dmg` | 177732696 | `4aaf57b8e160f8801ec870d9317635f44e4d82e21dbfcfafb0a7b520ee2b4018` |
| Firefox Nightly | `https://download.mozilla.org/?product=firefox-nightly-latest-ssl&os=osx&lang=en-US` | `https://download-installer.cdn.mozilla.net/pub/firefox/nightly/latest-mozilla-central/firefox-156.0a1.en-US.mac.dmg` | 2026-08-21T22:51:59Z | `Firefox-Nightly-156.0a1.dmg` | 181555126 | `f4fe27c93adf5b8336e114f77d7d236f9a72923f0b3bbdb7d6955e6d807e0d6c` |
| Opera network bootstrapper, not used for install | `https://net.geo.opera.com/opera/stable/mac` | same | 2026-08-21T22:51:51Z | `Opera-Stable-Mac.zip` | 3591704 | `8c4a1ee7e6f970583a2056e0a49d441a1bf88559d34aed040ec857a9249b14aa` |
| Opera full offline package | `https://download.opera.com/download/get/?id=79911&location=415&nothanks=yes&sub=marine&utm_tryagain=yes` | `https://download3.operacdn.com/ftp/pub/opera/desktop/135.0.5973.41/mac/Opera_135.0.5973.41_Setup.dmg` | 2026-08-21T23:05:02Z | `Opera_135.0.5973.41_Setup.dmg` | 260489614 | `12f5a0afe3d8544ca1a22eaa9c18da1547ae001eebb9f9ca08ddb1548243b7b4` |
| Arc | `https://releases.arc.net/release/Arc-latest.dmg` | `https://releases.arc.net/release/Arc-1.161.1-85803.dmg` | 2026-08-21T22:51:46Z | `Arc-latest.dmg` | 446402611 | `36e96867755be036e6c09485eec0e058ad17eb077589f092b2fae58eb5818648` |
| Orion | `https://orionbrowser.com/download/installer` | `https://cdn.kagi.com/downloads/OrionInstaller.dmg` | 2026-08-21T22:51:41Z | `OrionInstaller.dmg` | 2199684 | `a73039b0408345ac89d390aa1c20eb1f1938708a17d56c6ad53a452c93382427` |

### Exact-artifact reproducibility download

After the initial staging directory had been cleaned, review remediation used a fresh `mktemp -d` directory, `/private/tmp/pickvia-browser-remediation.yNnc5z`. The 17 artifacts that supplied an installed or blocked matrix row were downloaded again from the exact first-party requested/final URLs above between `2026-08-21T16:34:09-0700` and `2026-08-21T16:35:50-0700`. The Opera bootstrapper was not downloaded again because it supplied no staged app and was not used for installation. All 17 byte sizes and SHA-256 values matched the frozen original evidence; in particular, none of the rolling Chrome, Brave, or Orion endpoints had drifted.

The fresh `shasum -a 256` transcript was:

```text
36e96867755be036e6c09485eec0e058ad17eb077589f092b2fae58eb5818648  Arc-1.161.1-85803.dmg
6cf2c205a153d477baf79506da3eaf6697cc0544b1f0f6797c096d601c92df33  Brave-Browser-Beta.dmg
d847d380f306f14524eda99f775048551487aaa69120a1ca9aed5976088686a0  Brave-Browser-Nightly.dmg
4aaf57b8e160f8801ec870d9317635f44e4d82e21dbfcfafb0a7b520ee2b4018  Firefox-Developer-155.0b3.dmg
f4fe27c93adf5b8336e114f77d7d236f9a72923f0b3bbdb7d6955e6d807e0d6c  Firefox-Nightly-156.0a1.dmg
1c65c6765e6810cb81c9969de230a740b896bca3cc0acab52999830060a80cf4  MicrosoftEdge-151.0.4129.101.pkg
e56ee05b1a3e20759459038c431344d3acd596d6590f4d79929b3ed15f60663d  MicrosoftEdgeBeta-152.0.4191.41.pkg
965e4fac32bc533d90b07dee138285f7f84cf95a96bdebc4f4c4484e32210226  MicrosoftEdgeCanary-153.0.4233.0.pkg
ce8c7164c60bc431d9a9c0bbb7aad38136d99d49152602bf5f1407ad2e43223f  MicrosoftEdgeDev-153.0.4224.0.pkg
12f5a0afe3d8544ca1a22eaa9c18da1547ae001eebb9f9ca08ddb1548243b7b4  Opera_135.0.5973.41_Setup.dmg
a73039b0408345ac89d390aa1c20eb1f1938708a17d56c6ad53a452c93382427  OrionInstaller.dmg
15058eae5299b2da373f46eebf968c65bcaf126992ed7beb7a31c556bdb271a1  SafariTechnologyPreview.dmg
06ada90cbef764c71c7d899f9196342c954d57b21316051f86a5667d8d12597a  Vivaldi.8.1.4087.70.universal.dmg
5b0a7b4588073bb10951e544cbe245c89e7319520484d56ed9cd37e5c7ab4c56  Vivaldi.8.2.4133.24.universal.dmg
dcff851fbb30bd4268e9b977b716134f4a7f6d4d660afd42b7a8faa9691803c5  chromium-1684265-mac-arm.zip
1b646bfdab94c7951e3ccb500d645a57c4736d994fb95814471fdd12aa7183b5  googlechromecanary.dmg
5b47c2e1a95babfcded108f6b2ef9f5f0ef2bf7dce208be2af77dba9a6739518  googlechromedev.dmg
```

## Container and signing verification

- All twelve DMGs returned `hdiutil: verify: checksum ... is VALID`.
- Both ZIPs returned `No errors detected in compressed data` from `unzip -tq`.
- All four Edge packages passed `pkgutil --check-signature` as `Developer ID Installer: Microsoft Corporation (UBF8T346G9)` with trusted timestamps. Their package hashes exactly matched Microsoft's update API.
- The Safari Technology Preview package passed `pkgutil --check-signature` as Apple Software with an Apple Software Update certificate chain.
- ZIP entry names were checked for absolute paths and `..` traversal before expansion.
- Vendor-page ownership, artifact origin, Developer ID organization, team identifier, strict verification, and Gatekeeper result were compared together. Observed identities were Apple Software; Google LLC (`EQHXZ8M8AV`); Microsoft Corporation (`UBF8T346G9`); Brave Software, Inc. (`KL8N8XSYF4`); Vivaldi Technologies AS (`4XF3XNRN6Y`); Mozilla Corporation (`43AQ936H96`); Opera Software AS (`A2P9LX4JPN`); The Browser Company of New York Inc. (`S6N382Y83G`); Kagi Inc. (`TFVG979488`); and Duck Duck Go, Inc. (`HKE973VLUW`).

### Extended-attribute normalization evidence

Chrome and Brave source bundles carried `com.apple.FinderInfo` metadata on signed nested files. The exact copy/normalization commands were:

```bash
ditto --noextattr --noqtn "$source" "$destination"
xattr -cr "$destination"
```

For newly installed channel editions, `source` was the app on the read-only mounted vendor DMG and `destination` was its disposable staging copy. For pre-existing Stable apps, `source` was the installed bundle and `destination` was under `/private/tmp/pickvia-browser-remediation.yNnc5z/disposable-installed-copies`; `xattr -cr` was never run against an installed bundle. The executable hash command was `shasum -a 256 "$bundle/Contents/MacOS/$executable"`; verification commands were `codesign --verify --deep --strict "$bundle"` and `spctl --assess --type execute -vv "$bundle"`.

| Bundle | Source | `FinderInfo` count, pre → post | Executable SHA-256, pre = post | Strict status, pre → post | Gatekeeper status, pre → post |
| --- | --- | ---: | --- | --- | --- |
| Google Chrome Dev | Read-only vendor DMG | 741 → 0 | `0d9579cdbb84cc37fad41debd1a3494e331e92a82fddb8ac6e0abf523edba47c` | 1 → 0 | 0 → 0; notarized Google LLC (`EQHXZ8M8AV`) |
| Google Chrome Canary | Read-only vendor DMG | 741 → 0 | `a6342a9efd1e24e7925f80373ab7a4ed5d9b12019afcf1ed24a43236e4c8ee7f` | 1 → 0 | 0 → 0; notarized Google LLC (`EQHXZ8M8AV`) |
| Brave Browser Beta | Read-only vendor DMG | 824 → 0 | `c21e62ffede048e89d1013ca79a12fdf2d6af068e9c48b9171624bcae98ff43f` | 1 → 0 | 0 → 0; notarized Brave Software, Inc. (`KL8N8XSYF4`) |
| Brave Browser Nightly | Read-only vendor DMG | 824 → 0 | `e16d973ce9dd3ed840c07087100fe3ee66327033f225857de902cde90346f998` | 1 → 0 | 0 → 0; notarized Brave Software, Inc. (`KL8N8XSYF4`) |
| Google Chrome Stable | Pre-existing installed source; normalized disposable copy only | 69 → 0 | `97385e62510154852fd10da11c697bf5066dcc300e3b0c31633bd52ad940b984` | 1 → 0 | 0 → 0; notarized Google LLC (`EQHXZ8M8AV`) |
| Google Chrome Beta | Pre-existing installed source; normalized disposable copy only | 69 → 0 | `d0d20ef6b0eb86e8ef50386bbd94c61de6a411ba727d99987f1d3fe1ada0d77d` | 1 → 0 | 0 → 0; notarized Google LLC (`EQHXZ8M8AV`) |
| Brave Browser Stable | Pre-existing installed source; normalized disposable copy only | 1009 → 0 | `49aa8f13129779a8f93ea5ff28accf5e892e3eb76e8fc5c764cac0d565445018` | 1 → 0 | 0 → 0; notarized Brave Software, Inc. (`KL8N8XSYF4`) |

All pre/post Gatekeeper outputs were `accepted` with `source=Notarized Developer ID` and the origin shown in the table. All post-normalization strict runs exited `0` with no output. The exact pre-normalization strict errors were:

```text
/private/tmp/pickvia-browser-remediation.yNnc5z/mounts/chrome-dev/Google Chrome Dev.app: resource fork, Finder information, or similar detritus not allowed
In subcomponent: /private/tmp/pickvia-browser-remediation.yNnc5z/mounts/chrome-dev/Google Chrome Dev.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/Current/Helpers/app_mode_loader

/private/tmp/pickvia-browser-remediation.yNnc5z/mounts/chrome-canary/Google Chrome Canary.app: resource fork, Finder information, or similar detritus not allowed
In subcomponent: /private/tmp/pickvia-browser-remediation.yNnc5z/mounts/chrome-canary/Google Chrome Canary.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/Current/Helpers/app_mode_loader

/private/tmp/pickvia-browser-remediation.yNnc5z/mounts/brave-beta/Brave Browser Beta.app: resource fork, Finder information, or similar detritus not allowed
In subcomponent: /private/tmp/pickvia-browser-remediation.yNnc5z/mounts/brave-beta/Brave Browser Beta.app/Contents/Frameworks/Brave Browser Beta Framework.framework/Versions/Current/Frameworks/Sparkle.framework

/private/tmp/pickvia-browser-remediation.yNnc5z/mounts/brave-nightly/Brave Browser Nightly.app: resource fork, Finder information, or similar detritus not allowed
In subcomponent: /private/tmp/pickvia-browser-remediation.yNnc5z/mounts/brave-nightly/Brave Browser Nightly.app/Contents/Frameworks/Brave Browser Nightly Framework.framework/Versions/Current/Frameworks/Sparkle.framework

/Applications/Google Chrome.app: resource fork, Finder information, or similar detritus not allowed

/Applications/Google Chrome Beta.app: resource fork, Finder information, or similar detritus not allowed

/Applications/Brave Browser.app: resource fork, Finder information, or similar detritus not allowed
In subcomponent: /Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/Current/Helpers/Brave Browser Helper (Alerts).app
```

The original installed Chrome Stable, Chrome Beta, and Brave Stable bundles remained byte-for-byte untouched. The remediation also made no changes to any installed bundle; all normalization was confined to exact, disposable destinations under the unique temporary directory.

## Exact installed descriptors

For every passing row, the `authorities` column is the exact chain emitted by the inspector. Chromium records the manual rejection summary because the inspector intentionally produces no success record for it. All rows except Chromium are installed and available at the listed path.

| Application | Path | Bundle ID | Display name | Executable | Version | Architectures | Team ID | Authorities | Executable SHA-256 | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Safari | `/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app` | `com.apple.Safari` | Safari | `Safari` | 27.0 | `x86_64,arm64e` | `not set` | `macOS Software Signing \| Apple Code Signing Certification Authority \| Apple Root CA` | `a629d441eeb880abda0975f5179babc9003c12d97d18b4a872a0461a324d54db` | Pre-existing; inspector pass |
| Safari Technology Preview | `/Applications/Safari Technology Preview.app` | `com.apple.SafariTechnologyPreview` | Safari Technology Preview | `Safari Technology Preview` | 27.0 | `x86_64,arm64e` | `not set` | `Software Signing \| Apple Code Signing Certification Authority \| Apple Root CA` | `75890716cf8e5d2b9902873f60b62aaedbd4ebe1c16efd83acf4d33a93e8c94f` | Installed; staged match pass |
| Chromium | Not installed | `org.chromium.Chromium` | Chromium | `Chromium` | 154.0.8017.0 | `arm64` | `not set` | `ad hoc/linker-signed; no certificate authorities` | `c7cc0d2a57be966b35f5c31d9b8a13e31433825aa70d70fd4d19d13b06df2cff` | **BLOCKED: strict codesign and Gatekeeper fail** |
| Google Chrome Stable | `/Applications/Google Chrome.app` | `com.google.Chrome` | Google Chrome | `Google Chrome` | 151.0.7922.172 | `x86_64,arm64` | `EQHXZ8M8AV` | `Developer ID Application: Google LLC (EQHXZ8M8AV) \| Developer ID Certification Authority \| Apple Root CA` | `97385e62510154852fd10da11c697bf5066dcc300e3b0c31633bd52ad940b984` | Pre-existing; normalized-copy identity pass |
| Google Chrome Beta | `/Applications/Google Chrome Beta.app` | `com.google.Chrome.beta` | Google Chrome Beta | `Google Chrome Beta` | 153.0.8010.5 | `x86_64,arm64` | `EQHXZ8M8AV` | `Developer ID Application: Google LLC (EQHXZ8M8AV) \| Developer ID Certification Authority \| Apple Root CA` | `d0d20ef6b0eb86e8ef50386bbd94c61de6a411ba727d99987f1d3fe1ada0d77d` | Pre-existing; normalized-copy identity pass |
| Google Chrome Dev | `/Applications/Google Chrome Dev.app` | `com.google.Chrome.dev` | Google Chrome Dev | `Google Chrome Dev` | 154.0.8013.2 | `x86_64,arm64` | `EQHXZ8M8AV` | `Developer ID Application: Google LLC (EQHXZ8M8AV) \| Developer ID Certification Authority \| Apple Root CA` | `0d9579cdbb84cc37fad41debd1a3494e331e92a82fddb8ac6e0abf523edba47c` | Installed; staged match pass |
| Google Chrome Canary | `/Applications/Google Chrome Canary.app` | `com.google.Chrome.canary` | Google Chrome Canary | `Google Chrome Canary` | 154.0.8016.0 | `x86_64,arm64` | `EQHXZ8M8AV` | `Developer ID Application: Google LLC (EQHXZ8M8AV) \| Developer ID Certification Authority \| Apple Root CA` | `a6342a9efd1e24e7925f80373ab7a4ed5d9b12019afcf1ed24a43236e4c8ee7f` | Installed; staged match pass |
| Microsoft Edge Stable | `/Applications/Microsoft Edge.app` | `com.microsoft.edgemac` | Microsoft Edge | `Microsoft Edge` | 151.0.4129.101 | `x86_64,arm64` | `UBF8T346G9` | `Developer ID Application: Microsoft Corporation (UBF8T346G9) \| Developer ID Certification Authority \| Apple Root CA` | `358b5f91612a07e8b54d4883ee489fbea0971f1040b6c17da1f938693f5676af` | Installed; staged match pass |
| Microsoft Edge Beta | `/Applications/Microsoft Edge Beta.app` | `com.microsoft.edgemac.Beta` | Microsoft Edge Beta | `Microsoft Edge Beta` | 152.0.4191.41 | `x86_64,arm64` | `UBF8T346G9` | `Developer ID Application: Microsoft Corporation (UBF8T346G9) \| Developer ID Certification Authority \| Apple Root CA` | `4dac466bd4ae83666a086b57f31cd9cd1b150f9cb7dde16e47fc25f79b946085` | Installed; staged match pass |
| Microsoft Edge Dev | `/Applications/Microsoft Edge Dev.app` | `com.microsoft.edgemac.Dev` | Microsoft Edge Dev | `Microsoft Edge Dev` | 153.0.4224.0 | `x86_64,arm64` | `UBF8T346G9` | `Developer ID Application: Microsoft Corporation (UBF8T346G9) \| Developer ID Certification Authority \| Apple Root CA` | `7c58857f88ec0f4321bc4fff84f07f94f2a2cbf0b55c118e1f198fe0d2ecc407` | Installed; staged match pass |
| Microsoft Edge Canary | `/Applications/Microsoft Edge Canary.app` | `com.microsoft.edgemac.Canary` | Microsoft Edge Canary | `Microsoft Edge Canary` | 153.0.4233.0 | `x86_64,arm64` | `UBF8T346G9` | `Developer ID Application: Microsoft Corporation (UBF8T346G9) \| Developer ID Certification Authority \| Apple Root CA` | `9c8ed221d6aecbd33479806f2e467925e4e49f00703b505f24b4cebfdb6ac5eb` | Installed; staged match pass |
| Brave Stable | `/Applications/Brave Browser.app` | `com.brave.Browser` | Brave Browser | `Brave Browser` | 151.1.93.138 | `arm64` | `KL8N8XSYF4` | `Developer ID Application: Brave Software, Inc. (KL8N8XSYF4) \| Developer ID Certification Authority \| Apple Root CA` | `49aa8f13129779a8f93ea5ff28accf5e892e3eb76e8fc5c764cac0d565445018` | Pre-existing; normalized-copy identity pass |
| Brave Beta | `/Applications/Brave Browser Beta.app` | `com.brave.Browser.beta` | Brave Browser Beta | `Brave Browser Beta` | 152.1.95.87 | `x86_64,arm64` | `KL8N8XSYF4` | `Developer ID Application: Brave Software, Inc. (KL8N8XSYF4) \| Developer ID Certification Authority \| Apple Root CA` | `c21e62ffede048e89d1013ca79a12fdf2d6af068e9c48b9171624bcae98ff43f` | Installed; staged match pass |
| Brave Nightly | `/Applications/Brave Browser Nightly.app` | `com.brave.Browser.nightly` | Brave Browser Nightly | `Brave Browser Nightly` | 152.1.96.6 | `x86_64,arm64` | `KL8N8XSYF4` | `Developer ID Application: Brave Software, Inc. (KL8N8XSYF4) \| Developer ID Certification Authority \| Apple Root CA` | `e16d973ce9dd3ed840c07087100fe3ee66327033f225857de902cde90346f998` | Installed; staged match pass |
| Vivaldi Stable | `/Applications/Vivaldi.app` | `com.vivaldi.Vivaldi` | Vivaldi | `Vivaldi` | 8.1.4087.70 | `x86_64,arm64` | `4XF3XNRN6Y` | `Developer ID Application: Vivaldi Technologies AS (4XF3XNRN6Y) \| Developer ID Certification Authority \| Apple Root CA` | `0f2cc5d01199367360486e4d04ad11e5d42ac082f540ed760b4b909f80fee337` | Installed; staged match pass |
| Vivaldi Snapshot | `/Applications/Vivaldi Snapshot.app` | `com.vivaldi.Vivaldi.snapshot` | Vivaldi Snapshot | `Vivaldi Snapshot` | 8.2.4133.24 | `x86_64,arm64` | `4XF3XNRN6Y` | `Developer ID Application: Vivaldi Technologies AS (4XF3XNRN6Y) \| Developer ID Certification Authority \| Apple Root CA` | `3c07a7ea2978fcf9e1f3bfd3bf26a3fa51f7b6427ebe06dd83f25b9c9cddeb99` | Installed; staged match pass |
| Firefox Stable | `/Applications/Firefox.app` | `org.mozilla.firefox` | Firefox | `firefox` | 153.0.3 | `x86_64,arm64` | `43AQ936H96` | `Developer ID Application: Mozilla Corporation (43AQ936H96) \| Developer ID Certification Authority \| Apple Root CA` | `149c634b1692bf373b1ebe716c5b4f11749731d16a9cd8b303d18c5af3c1009e` | Pre-existing; inspector pass |
| Firefox Developer Edition | `/Applications/Firefox Developer Edition.app` | `org.mozilla.firefoxdeveloperedition` | Firefox Developer Edition | `firefox` | 155.0 | `x86_64,arm64` | `43AQ936H96` | `Developer ID Application: Mozilla Corporation (43AQ936H96) \| Developer ID Certification Authority \| Apple Root CA` | `9a2573cabc186a462746d63dccdecca58950916b188c9c6bc7351f2187e952cb` | Installed; staged match pass |
| Firefox Nightly | `/Applications/Firefox Nightly.app` | `org.mozilla.nightly` | Firefox Nightly | `firefox` | 156.0a1 | `x86_64,arm64` | `43AQ936H96` | `Developer ID Application: Mozilla Corporation (43AQ936H96) \| Developer ID Certification Authority \| Apple Root CA` | `fa25bde3cd9a997b0b7a9d4a48ddabd4ab134aec75e865b98309da6deb113df8` | Installed; staged match pass |
| DuckDuckGo | `/Applications/DuckDuckGo.app` | `com.duckduckgo.macos.browser` | DuckDuckGo | `DuckDuckGo` | 1.203.0 | `x86_64,arm64` | `HKE973VLUW` | `Developer ID Application: Duck Duck Go, Inc. (HKE973VLUW) \| Developer ID Certification Authority \| Apple Root CA` | `a774871988511bdea99e9b752b1e8bdb6b23e0683ba7c111f39577a431ef0194` | Pre-existing; inspector pass |
| Opera | `/Applications/Opera.app` | `com.operasoftware.Opera` | Opera | `Opera` | 135.0 | `x86_64,arm64` | `A2P9LX4JPN` | `Developer ID Application: Opera Software AS (A2P9LX4JPN) \| Developer ID Certification Authority \| Apple Root CA` | `7d559460ff879a29ca23dddab7c01dddb59edd3596dfa124cfdf25ab85168626` | Installed; staged match pass |
| Arc | `/Applications/Arc.app` | `company.thebrowser.Browser` | Arc | `Arc` | 1.161.1 | `x86_64,arm64` | `S6N382Y83G` | `Developer ID Application: The Browser Company of New York Inc. (S6N382Y83G) \| Developer ID Certification Authority \| Apple Root CA` | `c42895c0ac48fe60357705a2ea6cfdb18a9b56e4b2c92b4a2af4d2a30b6ea2ed` | Installed; staged match pass |
| Orion | `/Applications/Orion.app` | `com.kagi.kagimacOS` | Orion | `Orion` | 1.0 | `x86_64,arm64` | `TFVG979488` | `Developer ID Application: Kagi Inc. (TFVG979488) \| Developer ID Certification Authority \| Apple Root CA` | `9521b612fe08ee530359bf046b56e52cc4c53569680b2fc2a5ebd2363dffb505` | Installed; staged match pass |

## Recreated staged-versus-installed evidence

Each of the 16 installed artifacts was mounted read-only or expanded without execution into `/private/tmp/pickvia-browser-remediation.yNnc5z`, then copied to `staged-apps/<official name>.app` with the normalization commands documented above. The unchanged inspector ran separately on the staged and installed paths. Its `path=` line was removed, the remaining eight lines were compared byte-for-byte, and the canonical transcript was hashed including its final newline:

```bash
staged_output=$("$inspector" "$staged")
installed_output=$("$inspector" "$installed")
staged_canonical=$(printf '%s\n' "$staged_output" | sed '/^path=/d')
installed_canonical=$(printf '%s\n' "$installed_output" | sed '/^path=/d')
test "$staged_canonical" = "$installed_canonical"
printf '%s\n' "$staged_canonical" | shasum -a 256
printf '%s\n' "$installed_canonical" | shasum -a 256
```

Thus each canonical digest covers the exact `bundle_id`, `display_name`, `executable`, `version`, `architectures`, `team_id`, `authorities`, and executable `sha256` values printed in the installed descriptor table. The paired transcript was:

| Application | Inspector exit, staged / installed | Canonical digest, staged | Canonical digest, installed | Executable SHA-256, staged | Executable SHA-256, installed | Exact field equality |
| --- | --- | --- | --- | --- | --- | --- |
| Safari Technology Preview | 0 / 0 | `80673d800f9b4cc8b02df3e8649676437431ebc19ef434796a5a836ebbd42c42` | `80673d800f9b4cc8b02df3e8649676437431ebc19ef434796a5a836ebbd42c42` | `75890716cf8e5d2b9902873f60b62aaedbd4ebe1c16efd83acf4d33a93e8c94f` | `75890716cf8e5d2b9902873f60b62aaedbd4ebe1c16efd83acf4d33a93e8c94f` | PASS |
| Google Chrome Dev | 0 / 0 | `7d791326904f1d3ecd4145ffe4e2f26273f142c666f62f0f92610a8bf3012b97` | `7d791326904f1d3ecd4145ffe4e2f26273f142c666f62f0f92610a8bf3012b97` | `0d9579cdbb84cc37fad41debd1a3494e331e92a82fddb8ac6e0abf523edba47c` | `0d9579cdbb84cc37fad41debd1a3494e331e92a82fddb8ac6e0abf523edba47c` | PASS |
| Google Chrome Canary | 0 / 0 | `ed40638326a356a971a5d0be1cad21e1daf5c44300baa2371f6fbac0923b9f0c` | `ed40638326a356a971a5d0be1cad21e1daf5c44300baa2371f6fbac0923b9f0c` | `a6342a9efd1e24e7925f80373ab7a4ed5d9b12019afcf1ed24a43236e4c8ee7f` | `a6342a9efd1e24e7925f80373ab7a4ed5d9b12019afcf1ed24a43236e4c8ee7f` | PASS |
| Microsoft Edge Stable | 0 / 0 | `95927e8bc066918b9229705440db7fb22f3c272e6f9976bbf74a2aca10393692` | `95927e8bc066918b9229705440db7fb22f3c272e6f9976bbf74a2aca10393692` | `358b5f91612a07e8b54d4883ee489fbea0971f1040b6c17da1f938693f5676af` | `358b5f91612a07e8b54d4883ee489fbea0971f1040b6c17da1f938693f5676af` | PASS |
| Microsoft Edge Beta | 0 / 0 | `e056c45d97d4cbb3d4cd82ce99309f959ab3e2483b117a2489d3afdadfd857af` | `e056c45d97d4cbb3d4cd82ce99309f959ab3e2483b117a2489d3afdadfd857af` | `4dac466bd4ae83666a086b57f31cd9cd1b150f9cb7dde16e47fc25f79b946085` | `4dac466bd4ae83666a086b57f31cd9cd1b150f9cb7dde16e47fc25f79b946085` | PASS |
| Microsoft Edge Dev | 0 / 0 | `d5bf6321090570a62a5adb14077f0d5a92582bc861f9b87382f796950bae017e` | `d5bf6321090570a62a5adb14077f0d5a92582bc861f9b87382f796950bae017e` | `7c58857f88ec0f4321bc4fff84f07f94f2a2cbf0b55c118e1f198fe0d2ecc407` | `7c58857f88ec0f4321bc4fff84f07f94f2a2cbf0b55c118e1f198fe0d2ecc407` | PASS |
| Microsoft Edge Canary | 0 / 0 | `ed8084447531eade249b2ae1736d96be627a1945d51c8fb34fc4e4137c430bf8` | `ed8084447531eade249b2ae1736d96be627a1945d51c8fb34fc4e4137c430bf8` | `9c8ed221d6aecbd33479806f2e467925e4e49f00703b505f24b4cebfdb6ac5eb` | `9c8ed221d6aecbd33479806f2e467925e4e49f00703b505f24b4cebfdb6ac5eb` | PASS |
| Brave Beta | 0 / 0 | `83f7e9159a88177a3a84cbed0d4c743099e96c44ca27390fc6c7d7be27cd02aa` | `83f7e9159a88177a3a84cbed0d4c743099e96c44ca27390fc6c7d7be27cd02aa` | `c21e62ffede048e89d1013ca79a12fdf2d6af068e9c48b9171624bcae98ff43f` | `c21e62ffede048e89d1013ca79a12fdf2d6af068e9c48b9171624bcae98ff43f` | PASS |
| Brave Nightly | 0 / 0 | `60d0424a071b03f4d7ece84123baefdf7eed0bfcaf5e99276480bfe7b4c34651` | `60d0424a071b03f4d7ece84123baefdf7eed0bfcaf5e99276480bfe7b4c34651` | `e16d973ce9dd3ed840c07087100fe3ee66327033f225857de902cde90346f998` | `e16d973ce9dd3ed840c07087100fe3ee66327033f225857de902cde90346f998` | PASS |
| Vivaldi Stable | 0 / 0 | `d26a5083fdd96eda3c56db69e6d559c4973f6df443c661a7348168099284a3d7` | `d26a5083fdd96eda3c56db69e6d559c4973f6df443c661a7348168099284a3d7` | `0f2cc5d01199367360486e4d04ad11e5d42ac082f540ed760b4b909f80fee337` | `0f2cc5d01199367360486e4d04ad11e5d42ac082f540ed760b4b909f80fee337` | PASS |
| Vivaldi Snapshot | 0 / 0 | `ea687d72e0dbddea363f97ef2ea32ec79cedb5c7c7ff7e418a5edf0f4be090b4` | `ea687d72e0dbddea363f97ef2ea32ec79cedb5c7c7ff7e418a5edf0f4be090b4` | `3c07a7ea2978fcf9e1f3bfd3bf26a3fa51f7b6427ebe06dd83f25b9c9cddeb99` | `3c07a7ea2978fcf9e1f3bfd3bf26a3fa51f7b6427ebe06dd83f25b9c9cddeb99` | PASS |
| Firefox Developer Edition | 0 / 0 | `29d3c7b33d993bfc7c241ac505863db118017c8618d4ab6e213d9d0fd36f4dc8` | `29d3c7b33d993bfc7c241ac505863db118017c8618d4ab6e213d9d0fd36f4dc8` | `9a2573cabc186a462746d63dccdecca58950916b188c9c6bc7351f2187e952cb` | `9a2573cabc186a462746d63dccdecca58950916b188c9c6bc7351f2187e952cb` | PASS |
| Firefox Nightly | 0 / 0 | `55f879b1401259d052d1f78c7e5c7e4b254b5e47f875e75d25ef0d5447b8fe68` | `55f879b1401259d052d1f78c7e5c7e4b254b5e47f875e75d25ef0d5447b8fe68` | `fa25bde3cd9a997b0b7a9d4a48ddabd4ab134aec75e865b98309da6deb113df8` | `fa25bde3cd9a997b0b7a9d4a48ddabd4ab134aec75e865b98309da6deb113df8` | PASS |
| Opera | 0 / 0 | `768799667cfc649fade2fa2455952408d32a438c38a7fa504c8f3eff80b0ebbb` | `768799667cfc649fade2fa2455952408d32a438c38a7fa504c8f3eff80b0ebbb` | `7d559460ff879a29ca23dddab7c01dddb59edd3596dfa124cfdf25ab85168626` | `7d559460ff879a29ca23dddab7c01dddb59edd3596dfa124cfdf25ab85168626` | PASS |
| Arc | 0 / 0 | `29766aacef647796bfb181542567bd94b8f25bbe978d2129c4d04a5c3c4ae7ea` | `29766aacef647796bfb181542567bd94b8f25bbe978d2129c4d04a5c3c4ae7ea` | `c42895c0ac48fe60357705a2ea6cfdb18a9b56e4b2c92b4a2af4d2a30b6ea2ed` | `c42895c0ac48fe60357705a2ea6cfdb18a9b56e4b2c92b4a2af4d2a30b6ea2ed` | PASS |
| Orion | 0 / 0 | `4a3a84f464be2bda735de90b504bbf0a3e4e32c138fa83ae087b45055fb88a61` | `4a3a84f464be2bda735de90b504bbf0a3e4e32c138fa83ae087b45055fb88a61` | `9521b612fe08ee530359bf046b56e52cc4c53569680b2fc2a5ebd2363dffb505` | `9521b612fe08ee530359bf046b56e52cc4c53569680b2fc2a5ebd2363dffb505` | PASS |

All 16 comparisons passed with no field, hash, version, or signing-identity mismatch.

Firefox Beta/ESR, Safari Beta, and Chrome Extended Stable are excluded from this matrix.

## Installation and post-install verification

- The user explicitly authorized all browser EULAs before installation resumed.
- Opera's initial ZIP contained only an EULA-gated network bootstrapper. The first-party offline link supplied a full valid DMG containing `Opera.app`, so the bootstrapper was not run.
- `OrionInstaller.dmg` directly contained `Orion.app`; no installer was run.
- The signed Safari Technology Preview and Edge packages were expanded without execution. Their inspected app payloads were copied under their official names, an installation mode explicitly allowed by this task.
- All sixteen destination names were checked immediately before copy. No collision occurred.
- Each new `/Applications` bundle passed the inspector after installation. All eight identity fields other than `path`, including executable SHA-256, matched the corresponding staged output exactly.
- No browser or installer UI was opened.

## Chromium blocker

The official `Mac_Arm/1684265` snapshot produced `Chromium.app` version `154.0.8017.0`, bundle ID `org.chromium.Chromium`, with an arm64 executable SHA-256 of `c7cc0d2a57be966b35f5c31d9b8a13e31433825aa70d70fd4d19d13b06df2cff`.

`codesign -dvvv` reports `flags=0x20002(adhoc,linker-signed)`, `Signature=adhoc`, `Info.plist=not bound`, `TeamIdentifier=not set`, and no sealed resources. `codesign --verify --deep --strict` fails with `code has no resources but signature indicates they must be present`; Gatekeeper fails with the same error. Installing it would violate the mandatory unsigned-bundle rejection contract, so Chromium remains uninstalled.

The fresh reconstruction first checked every ZIP entry for an absolute path or `..` component and recorded `entry_traversal_check=PASS status=0`. Against the safely expanded app, the inspector exited `1` with `error: bundle is not validly signed`; both the direct strict-signature check and Gatekeeper assessment exited `1` with the exact error above.

## Cleanup

For the original run, all twelve disk images were detached and the exact owned staging directory `/private/tmp/pickvia-browser-matrix.Jlmb7U` was removed after evidence and installed matches were frozen. For review remediation, evidence was first preserved in commit `78a2a2d1d7d14ea768df59d3869a4e6d1c608b4d`; only then were all twelve read-only images detached and the exact, ownership-validated directories `/private/tmp/pickvia-browser-remediation.yNnc5z` and `/private/tmp/pickvia-inspector-repro.Kx08YQ` removed. Both paths were verified absent after removal. The contract's unique per-run fixture directories were removed by its `EXIT` trap. All installed browser apps remain in `/Applications`.
