# PickVia

<!-- Generated language navigation -->
**English** · [简体中文](docs/readme/README.zh-Hans.md) · [繁體中文](docs/readme/README.zh-Hant.md) · [日本語](docs/readme/README.ja.md) · [한국어](docs/readme/README.ko.md) · [Español](docs/readme/README.es.md) · [Français](docs/readme/README.fr.md) · [Deutsch](docs/readme/README.de.md) · [Português (Brasil)](docs/readme/README.pt-BR.md) · [Русский](docs/readme/README.ru.md) · [العربية](docs/readme/README.ar.md) · [हिन्दी](docs/readme/README.hi.md)
<!-- End language navigation -->

<p align="center">
  <img src="Support/Icons/PickViaArtwork.png" alt="PickVia app icon" width="128">
</p>

<p align="center"><strong>Stop opening links in the wrong browser or profile.</strong></p>

macOS can reuse the wrong browser window or profile, while every `mailto:` link
goes to one fixed default mail app. PickVia asks where to open each link, so you
choose the browser profile or installed mail app you actually need.

**[Visit the PickVia website](https://kiteretsu903.github.io/pick-via/)** for
screenshots, release highlights, and the [changelog](https://kiteretsu903.github.io/pick-via/changelog.html).

<p align="center">
  <img src="docs/screenshots/pickvia-browser-chooser-backdrop@2x.png" alt="PickVia browser chooser with native macOS translucent material" width="900">
</p>

## Languages

PickVia v1.5.1 supports 80 app and website languages, including a language
selector and right-to-left layouts, plus 12 README languages. Choose the app language
in Settings or follow the primary system language. Product screenshots show
the English interface.

## Download

**[Download PickVia v1.5.1 for macOS](https://github.com/kiteretsu903/pick-via/releases/latest)**

PickVia requires **macOS 14 Sonoma or later** on **Apple Silicon** and handles
HTTP, HTTPS, and `mailto:` links.

## What it does

- **Choose a browser or profile for each web link.**
- **Choose an installed mail app for each email link.**
- **Handle links locally without saving opened-link history.**

## Mail chooser

<p align="center">
  <img src="docs/screenshots/pickvia-mail-chooser-backdrop@2x.png" alt="PickVia mail chooser with native macOS translucent material" width="900">
</p>

## Configure once

Enable, disable, reorder, and rescan browser targets and registered mail apps in
Settings.

<p align="center">
  <img src="docs/screenshots/pickvia-settings@2x.png" alt="PickVia browser settings with synthetic browser profiles" width="900">
</p>

## Install

1. Download and open `PickVia-v1.5.1.dmg` from the
   [GitHub release](https://github.com/kiteretsu903/pick-via/releases/latest).
2. Drag **PickVia** to the **Applications** folder shown in the installer.
3. Open **PickVia** from Applications and follow the welcome flow.
4. Choose **Set as Default**. macOS asks separately for permission to handle
   HTTP and HTTPS links.
5. Optionally review your installed mail applications and make PickVia the
   default handler for `mailto:` links, or choose **Skip Mail Setup**.

### First launch and Gatekeeper

PickVia v1.5.1 is signed with an Apple Development certificate and is not notarized. macOS may block the first
launch of the downloaded app. If you downloaded it from the GitHub release and
choose to trust it:

1. Try to open PickVia once and dismiss the warning.
2. Open **System Settings → Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway**, then confirm **Open**. The button is available for
   about one hour after the blocked launch attempt.

If **Open Anyway** is unavailable, ensure **PickVia.app** is in Applications,
try the blocked launch once, then run:

```zsh
xattr -dr com.apple.quarantine "/Applications/PickVia.app"
```

Apple documents this Gatekeeper override and its security implications in
[Safely open apps on your Mac](https://support.apple.com/en-asia/102445).

## Browser support

| Browser / editions | Profiles | Normal | Private window |
|---|---:|---:|---:|
| Safari | Experimental | Yes | No |
| Safari Technology Preview | No | Yes | No |
| DuckDuckGo | No | Yes | Yes* |
| Chrome Stable / Beta / Dev / Canary, Chromium | Yes | Yes | Yes |
| Edge Stable / Beta / Dev / Canary | Yes | Yes | Yes |
| Brave Stable / Beta / Nightly | Yes | Yes | Yes |
| Vivaldi Stable / Snapshot | Yes | Yes | Yes |
| Firefox Stable / Developer Edition / Nightly | Yes | Yes | Yes |
| Opera, Arc, Orion | No | Yes | No |

\* DuckDuckGo Private uses isolated, disposable state on compatible unsandboxed
builds, without a version restriction. It requires neither a DuckDuckGo
extension nor Accessibility access. Normal DuckDuckGo links do not require a
particular version or publisher signature. Private state is cleaned after its
browser process exits while PickVia is running, or on a subsequent startup/route.

Each installed edition appears as a separate browser with its own name and icon.
Firefox profiles associated with another installed edition are excluded from that
browser's profile list. Association follows Firefox's recorded application path;
profiles with missing or unrecognized metadata retain the existing fallback and
may appear under more than one edition.

Browser-level Default targets work without profile access; granting access adds
discovered profiles. Private windows are browser-level choices: combining a
specific profile with private mode is not supported. Opera, Arc, and Orion
currently offer normal app-level routing only.

Support varies by browser version and startup state.

## Safari profiles (experimental)

Enable Safari Stable profiles in Browser Settings. This opt-in feature requires
Accessibility (Device Control and Data Access on macOS 27 or later) and Automation
permissions. Each link opens in a new window of the selected profile. Safari
profile routing remains experimental.

For local builds, set `PICKVIA_SIGNING_IDENTITY` to your codesigning certificate
fingerprint, or save it in the ignored `.signing-identity` file, then run
`scripts/build-app.sh`. Keep the same identity across rebuilds to preserve app
identity for macOS permissions.

## Mail support

PickVia handles `mailto:` links only, discovering installed applications that
macOS registers for email links and offering app-level choices—not accounts,
profiles, identities, or compose modes. Mail Settings can enable, disable,
reorder, and rescan registered handlers; mail setup remains optional during
onboarding.

## Privacy

- Opened URLs are handled locally; PickVia never sends, logs, or persists them.
- PickVia does not access browsing history, cookies, sessions, saved passwords,
  or page content.
- The mail chooser does not preview, log, or persist recipients, subjects,
  message bodies, or the original `mailto:` request.

Remove profile-access grants in **Browser Settings → Profile Access → Remove Access**.

See the full [Privacy Policy](https://kiteretsu903.github.io/pick-via/privacy.html).

## License

MIT. See [LICENSE](LICENSE).
