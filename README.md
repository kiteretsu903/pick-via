# PickVia

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

## Download

**[Download PickVia v1.3 for macOS](https://github.com/kiteretsu903/pick-via/releases/latest)**

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

1. Download and open `PickVia-v1.3.dmg` from the
   [GitHub release](https://github.com/kiteretsu903/pick-via/releases/latest).
2. Drag **PickVia** to the **Applications** folder shown in the installer.
3. Open **PickVia** from Applications and follow the welcome flow.
4. Choose **Set as Default**. macOS asks separately for permission to handle
   HTTP and HTTPS links.
5. Optionally review your installed mail applications and make PickVia the
   default handler for `mailto:` links, or choose **Skip Mail Setup**.

### First launch and Gatekeeper

PickVia v1.3 is ad-hoc signed and not notarized. macOS may block the first
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

| Browser family | Profiles | Normal | Private |
|---|---:|---:|---:|
| Safari | No | Yes | No |
| DuckDuckGo | No | Yes | Yes* |
| Chrome, Chrome Beta, Chromium, Edge, Brave, Vivaldi | Yes | Yes | Yes |
| Firefox | Yes | Yes | Yes |

\* DuckDuckGo Private uses isolated, disposable state and is supported only by
official direct-download builds; it requires neither a DuckDuckGo extension nor Accessibility access.

Safari has one normal target; Chromium-family browsers and Firefox keep a
Default target without profile access, while granting access adds discovered profiles.

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
