# Changelog

## v1.2 — 2026-08-18

PickVia now supports Google Chrome Beta as a separate browser.

- Discover Google Chrome Beta by its official macOS bundle identifier.
- Keep Beta profiles separate from stable Google Chrome profile storage.
- Offer Chrome Beta browser-default and discovered-profile targets in normal
  and private modes.
- Resolve and validate the trusted Google Chrome Beta executable before launch.

PickVia v1.2 is ad-hoc signed and not notarized. See the README's Gatekeeper
instructions before the first launch.

## v1.1 — 2026-08-14

PickVia now routes email links as well as web links.

- Choose an installed mail application whenever you open a `mailto:` link.
- Discover applications registered with macOS for email links automatically.
- Enable, disable, reorder, and rescan mail applications in Mail Settings.
- Configure mail routing during the optional onboarding flow, or skip it and
  keep your current default mail application.
- Keep recipients, subjects, message bodies, and the original `mailto:` request
  out of the chooser, clipboard, logs, and saved configuration.
- Preserve authoritative browser and mail configuration during rescans,
  onboarding transitions, settings sessions, and launch recovery.
- Add Retina product screenshots showing browser, profile, and mail workflows.

PickVia v1.1 is ad-hoc signed and not notarized. See the README's Gatekeeper
instructions before the first launch.

## v1.0 — 2026-08-14

First public release of PickVia.

- Choose a browser target for every HTTP and HTTPS link.
- Support Safari, Chrome, Chromium, Edge, Brave, Vivaldi, and Firefox.
- Use discovered Chromium-family and Firefox profiles, plus normal and private
  targets where supported.
- Keep the chooser on the current macOS Desktop and prepare it after launch for
  faster first use.
- Package the app in a drag-to-Applications DMG installer.

PickVia v1.0 is ad-hoc signed and not notarized. See the README's Gatekeeper
instructions before the first launch.
