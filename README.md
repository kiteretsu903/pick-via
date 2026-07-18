# PickVia

PickVia is a local, menu-bar-only macOS browser chooser. It handles HTTP and HTTPS links and lets you choose an installed Safari, Chromium-family, or Firefox target each time.

## Requirements

- macOS 14 Sonoma or newer
- Xcode and the Swift 6 toolchain
- A locally built, non-sandboxed app bundle

## Test and build

```zsh
swift test
zsh scripts/build-app.sh
zsh scripts/smoke-test.sh build/PickVia.app
```

The build script creates and ad-hoc signs `build/PickVia.app`. Start it with:

```zsh
open build/PickVia.app
```

On first run, scan the installed browsers, review the resulting targets, and use **Set as Default**. macOS asks for consent to handle HTTP and HTTPS; PickVia does not change the default handler during build or automated tests.

## Browser capabilities

| Browser family | Profiles | Normal | Private | Launch method |
|---|---:|---:|---:|---|
| Safari | No | Yes | No | macOS workspace |
| Chrome, Chromium, Edge, Brave, Vivaldi | Yes | Yes | Yes | Direct executable arguments |
| Firefox | Yes | Yes | Yes | Direct executable arguments |

Configuration is stored at `~/Library/Application Support/PickVia/PickViaConfig.json`. Small preferences are stored in the app's user defaults domain. PickVia does not persist opened URLs.

## Browser Profile Access

macOS can protect browser profile folders from automatic access. When profile discovery is blocked, PickVia asks for one exact data root per affected browser: `~/Library/Application Support/Google/Chrome`, `~/Library/Application Support/Chromium`, `~/Library/Application Support/Microsoft Edge`, `~/Library/Application Support/BraveSoftware/Brave-Browser`, `~/Library/Application Support/Vivaldi`, or `~/Library/Application Support/Firefox`. Chromium-family roots are validated and scanned by reading only their `Local State` marker; the Firefox root is validated and scanned by reading only `profiles.ini`. PickVia does not read browsing history, cookies, sessions, saved passwords, or page content.

Each installed Chromium-family or Firefox browser has a browser-level Default
target that launches without a profile-selection argument. Default remains
usable without profile-folder access; granting the browser root adds its named
profiles.

The chooser opens beside the current pointer, flips away from display edges,
and grows to show every target when the display has room. Browser Settings uses
the labeled Profile Access action to show or repair browser-root grants.

The selected grant is stored as read-only security-scoped bookmark bytes in `~/Library/Application Support/PickVia/ProfileAccessBookmarks.json`, keyed separately for each browser. The signed local bundle has been verified to restore these grants after an ordinary quit and relaunch. Routing configuration remains separate in `~/Library/Application Support/PickVia/PickViaConfig.json`.

To revoke a grant, open **Browser Settings**, choose **Profile Access**, and use **Remove Access** for that browser. If you skip access, remove it, or a saved grant can no longer be resolved, PickVia falls back to browser-level normal and private targets; detected profile-specific targets may remain listed but unavailable until access is restored. Existing manual targets are preserved.

## Current MVP exclusions

PickVia does not include routing rules, remembered domain choices, URL rewriting, browser extensions, Safari profiles/private windows, mail or file routing, sync, analytics, updates, or App Store distribution.
