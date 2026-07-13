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

## Current MVP exclusions

PickVia does not include routing rules, remembered domain choices, URL rewriting, browser extensions, Safari profiles/private windows, mail or file routing, sync, analytics, updates, or App Store distribution.
