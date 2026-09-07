# Safari profile routing: code and API research

**Conclusion:** Safari profile support is feasible in PickVia through an optional Accessibility/Automation adapter. This is the approach demonstrated by other implementations. No public direct “open this URL in profile X” API was found in the interfaces checked. An extension-based design is plausible but remains a prototype, especially for a profile with no open window.

Research date: 2026-09-06. This is source inspection and API validation, not a live Safari routing test. No Safari profile, permission, Focus setting, or default-browser setting was changed; no personal Safari database was read. Product code and the released app were not changed.

## What other applications actually do

| Project | Evidence inspected | Finding |
|---|---|---|
| OpenIn | Author’s [4.1 implementation explanation](https://loshadki.app/blog/2023-08-23-openin-4-1/) and [4.3 update](https://loshadki.app/blog/2025-07-14-betas/) | The author explicitly describes relying on macOS Automation and scripting because Safari lacks a Chromium-style external profile selector. The original implementation required profile name/order; 4.3 advertises automatic discovery and support across locales. Its proprietary implementation was not inspected. |
| Browser Picker | [SafariLauncher.swift](https://github.com/mertizci/browser-picker/blob/e3eaaca19c517fa80d8e1ce54e6b54e0c04272fb/BrowserPicker/Browsers/SafariLauncher.swift#L4) | Uses AppleScript plus System Events. Attempts to reuse windows based on title prefixes; otherwise clicks a matching profile menu item, waits, and sets the front window’s tab URL. |
| Safari Profile Router | [SafariLauncher.swift](https://github.com/bradystroud/safari-profile-router/blob/7854e31cab25d5e56145af80b2537191d26e7e8a/URLRouter/Services/SafariLauncher.swift#L5) | Same basic window/menu automation. Uses English menu names and falls back to ordinary Safari routing when automation fails. |
| Finicky | [launcher.go](https://github.com/johnste/finicky/blob/a01a9b79ad7c688d16ca8d442fcc46cf5114738a/apps/finicky/src/browser/launcher.go#L150) | Profile argument resolution handles Chromium and Firefox. Safari falls through without a profile selector. |
| AppCat | [ProfileDetector.swift](https://github.com/rmarinsky/AppCat/blob/7df8d8e7654bb57c631422d60abb73e45103708d/AppCat/Services/ProfileDetector.swift#L16) | Profile discovery handles Chromium and Firefox; listing Safari as a browser does not establish Safari profile support. |
| Velja | [Developer FAQ](https://sindresorhus.com/velja#can-you-support-safari-profiles) | States that Safari lacks an external profile-opening interface, including on macOS 26; links to requests for AppleScript and Shortcuts support. This is consistent with choosing not to implement the UI workaround. |

A smaller integration option also exists: Loshadki’s [ProfileLauncher documents a URL scheme](https://loshadki.app/profilelauncher/) carrying a browser bundle ID, profile name and one or more URLs. This could support an optional external helper. Its exported launcher apps do not themselves accept arbitrary URLs according to the same page; the documented URL scheme is the relevant interface. This introduces a separate dependency and its permissions rather than removing the automation requirement.

## API findings

### Direct AppleScript / Apple Events

The installed `/Applications/Safari.app/Contents/Resources/Safari.sdef` exposes windows, tabs, current tabs and URL properties. It has no profile class, profile property or profile-targeted open command. The installed version is Safari 27.0, build 22625.1.29.11.26, on macOS 27.0 build 26A5425a.

The useful distinction is between scripting Safari’s supported tab API and scripting its user interface through System Events. The latter can click a profile menu item even though the former cannot specify a profile. Apple documents [UI automation through System Events and Accessibility](https://developer.apple.com/library/archive/documentation/LanguagesUtilities/Conceptual/MacAutomationScriptingGuide/AutomatetheUserInterface.html).

No verified Safari command-line flag or URL scheme accepting a profile was found. Passing an invented `--profile` option to `open -a Safari` is not evidence that Safari recognizes it. A successful process launch would not prove profile selection.

### SafariServices and web extensions

I inspected `SFSafariApplication.h` and `SFSafariWindow.h` in the installed macOS 26.5 SDK. `openWindow(with:completionHandler:)`, `openTab(with:makeActiveIfPossible:completionHandler:)`, and `dispatchMessage(withName:toExtensionWithIdentifier:userInfo:completionHandler:)` have no destination-profile argument.

A local Swift compile-only probe successfully typechecked those API calls and `SFExtensionProfileKey`. It was not executed. The SDK is older than the installed macOS 27 beta, so the header audit is specifically a macOS 26.5 SDK finding, supplemented by the installed Safari 27 scripting dictionary and current public documentation.

[`SFExtensionProfileKey`](https://developer.apple.com/documentation/safariservices/sfextensionprofilekey) identifies the profile that sent a native extension message. It is not a documented destination selector. Apple’s [WWDC23 extension session](https://developer.apple.com/videos/play/wwdc2023/10119/) explains that each profile gets its own extension instance and storage, and each instance can access only that profile’s windows and tabs.

This suggests a possible design: pair an enabled extension instance with a PickVia profile entry; let that instance request a queued URL from the native host and open it within its own profile. That is an inference, not an existing verified PickVia capability. Reliable wake-up with Safari closed or with no window in the chosen profile remains unresolved. [WebKit issue 283762](https://bugs.webkit.org/show_bug.cgi?id=283762) reports that native `dispatchMessage` broadcasts to extension instances across open profiles and requests a targeted interface; it remains NEW in the inspected tracker. A prototype must not broadcast the URL and assume only the desired profile receives it.

Extensions also change installation/distribution: Apple documents per-profile enablement and [Safari web extension distribution through an Apple Developer Program membership](https://developer.apple.com/documentation/safariservices/safari-web-extensions). This is a separate integration project for PickVia’s current ad-hoc distribution.

### Shortcuts and Focus

The installed SafariLinkExtension action resources contain New Tab, Open Tab Group, and Set Profile/Set Profile or Tab Group. The description for the profile-setting action explicitly refers to the profile or tab group used during a Focus. The New Tab description refers to the current Tab Group. Resource strings alone do not prove a callable action with arbitrary URL-plus-profile parameters.

`shortcuts run --help` confirms named-shortcut execution with file input/output; it does not supply a Safari profile selector. Apple documents [Focus filters and website-to-profile rules](https://support.apple.com/en-ie/105100), but those control global browser context or site preferences. Website rules also have an already-open-site exception. They do not establish reliable per-request routing from PickVia. No Shortcut was created or run in this research, so a Tab Group helper remains unverified rather than ruled out.

### Discovering profiles

Browser Picker’s [SafariProfileStore.swift](https://github.com/mertizci/browser-picker/blob/e3eaaca19c517fa80d8e1ce54e6b54e0c04272fb/BrowserPicker/Browsers/ProfileDiscovery/SafariProfileStore.swift) reads profile records from `SafariTabs.db` with a query selecting bookmark records of specific types. This is an undocumented database schema, and the project offers Full Disk Access when the database is blocked.

Its [SafariMenuProfileScanner.swift](https://github.com/mertizci/browser-picker/blob/e3eaaca19c517fa80d8e1ce54e6b54e0c04272fb/BrowserPicker/Browsers/ProfileDiscovery/SafariMenuProfileScanner.swift) provides an alternative: read profile choices from Safari’s File menu using Accessibility. A PickVia prototype can use menu discovery or user-provided names without requiring Full Disk Access merely to enumerate profiles.

## What to reuse conceptually, and what to avoid

The useful flow is: select the requested profile’s New Window action, identify the resulting window, then open the URL in that exact window.

The inspected code has limitations we should not inherit blindly:

- Substring menu matching can confuse names such as Work and Work 2.
- Common-prefix/suffix stripping can erase part of profile names: New Work 1 Window and New Work 2 Window reduce to 1 and 2.
- Window-title prefixes are assumptions, not a documented profile identity API. Page titles and localization can complicate matching.
- Fixed delays followed by writing to the front window can race with a user changing focus. This is particularly relevant to keeping the user’s other desktop work undisturbed; putting a window on HUYAN does not isolate global input/focus.
- Falling back to ordinary Safari after a requested-profile failure can put a link into the wrong account context. PickVia should return a clear routing error instead.
- Neither of the two directly relevant routing repositories contained a top-level license file at the inspected commits. Treat them as implementation references; do not copy substantial code without establishing reuse permission.

## Recommended PickVia approach

Start with a small, independently written Accessibility adapter, enabled only when the user opts into Safari profile routing. Native AX calls could avoid the separate System Events scripting hop, though Safari Apple Events would still need Automation permission if used for URL delivery. Determine the exact permission needs in the prototype rather than promising a permission-free feature.

Initially create a fresh window for the chosen profile instead of trying to guess the owner of an existing window from its title. Read a fresh menu, require an unambiguous selection, identify the new window, and fail without opening the URL if the window association cannot be established. Preserve normal Safari routing for users who do not enable the adapter.

Acceptance cases for a later prototype: cold Safari, running Safari with multiple profiles, chosen profile with no open window, renamed and similarly named profiles, non-English menus, denied/revoked permissions, an already-open destination site in another profile, and concurrent user focus changes. Use two disposable profiles with distinct local cookie markers to prove the receiving account context, not just a page title or process exit code.

This is substantially more concrete than the earlier “maybe Shortcuts” assessment: the UI automation route is supported by real source code and OpenIn’s own explanation. It still needs PickVia-specific E2E proof before becoming a supported capability.

## Local evidence

Read-only source checkouts and the compile-only probe are retained under `/private/tmp/pickvia-safari-research-20260906/`. No third-party checkout was built or executed. This research note is local and uncommitted.
