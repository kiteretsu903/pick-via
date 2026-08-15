# PickVia

<p align="center">
  <img src="Support/Icons/PickViaArtwork.png" alt="PickVia app icon" width="128">
</p>

<p align="center"><strong>Choose where every link opens.</strong></p>

PickVia is a fast, local menu-bar app for macOS. Make it your default browser,
then choose the exact browser, profile, and normal or private window you want
every time you open an HTTP or HTTPS link.

## Download

**[Download PickVia v1.0 for macOS](https://github.com/kiteretsu903/pick-via/releases/latest)**

PickVia requires **macOS 14 Sonoma or later** on **Apple Silicon**.

## What it does

- **Choose at the moment it matters.** Every web link opens a focused chooser
  beside your pointer instead of silently taking over an existing browser.
- **Use the browser and profile you mean.** Pick Safari, Chrome, Chromium,
  Edge, Brave, Vivaldi, or Firefox; supported browsers can expose their normal,
  private, and discovered profile targets.
- **Stay out of the way.** PickVia lives in the menu bar and has no Dock icon.
- **Keep link handling local.** PickVia does not send, log, or persist opened
  URLs. Its configuration stays in your Application Support folder.
- **Keep profile access deliberate.** If macOS protects a browser's profile
  folder, PickVia asks only for that browser's exact data root. You can remove
  the grant at any time in Browser Settings.

## Install

1. Download and open `PickVia-v1.0.dmg` from the
   [GitHub release](https://github.com/kiteretsu903/pick-via/releases/latest).
2. Drag **PickVia** to the **Applications** folder shown in the installer.
3. Open **PickVia** from Applications and follow the welcome flow.
4. Choose **Set as Default**. macOS asks separately for permission to handle
   HTTP and HTTPS links.

### First launch and Gatekeeper

PickVia v1.0 is ad-hoc signed and not notarized. macOS will block the first
launch of the downloaded app. If you have downloaded it from this GitHub
release and choose to trust it:

1. Try to open PickVia once and dismiss the warning.
2. Open **System Settings → Privacy & Security** and scroll to **Security**.
3. Click **Open Anyway**, then confirm **Open**. The button is available for
   about one hour after the blocked launch attempt.

Apple documents this Gatekeeper override and its security implications in
[Safely open apps on your Mac](https://support.apple.com/en-asia/102445).

## Browser support

| Browser family | Profiles | Normal | Private |
|---|---:|---:|---:|
| Safari | No | Yes | No |
| Chrome, Chromium, Edge, Brave, Vivaldi | Yes | Yes | Yes |
| Firefox | Yes | Yes | Yes |

Safari has one normal-window target. Chromium-family browsers and Firefox keep
a browser-level Default target even if you choose not to grant profile access;
granting access adds discovered profiles.

## Privacy

PickVia stores browser target configuration in
`~/Library/Application Support/PickVia/PickViaConfig.json`. It does not persist
the links you open. When you grant profile access, the app stores only a
read-only security-scoped bookmark for the browser data root; it does not read
browsing history, cookies, sessions, saved passwords, or page content.

To remove a profile-access grant, open **Browser Settings → Profile Access**
and choose **Remove Access** for that browser.

## License

MIT. See [LICENSE](LICENSE).
