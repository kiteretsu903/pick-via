# Browser Editions and New Families Design

## Goal

Expand PickVia's explicit browser catalog to cover common co-installable editions of
Safari, Chrome, Edge, Brave, Vivaldi, and Firefox, plus the Opera, Arc, and Orion
families. Download and install the official macOS applications, then verify actual
normal, profile-specific, and private routing end to end wherever a stable,
permissionless integration exists.

The feature must preserve PickVia's existing browser grouping, keyboard-first chooser,
local URL handling, and failure semantics. It must not claim a profile or private-mode
capability merely because a browser presents that feature in its own UI.

## Supported Application Matrix

The implementation covers these applications as distinct PickVia browser groups:

| Family | Applications and editions |
|---|---|
| Safari | Safari, Safari Technology Preview |
| Chrome | Google Chrome, Google Chrome Beta, Google Chrome Dev, Google Chrome Canary |
| Chromium | Chromium, retained as an existing regression baseline |
| Edge | Microsoft Edge, Microsoft Edge Beta, Microsoft Edge Dev, Microsoft Edge Canary |
| Brave | Brave Browser, Brave Beta, Brave Nightly |
| Vivaldi | Vivaldi, Vivaldi Snapshot |
| Firefox | Firefox, Firefox Developer Edition, Firefox Nightly |
| Opera | Opera |
| Arc | Arc |
| Orion | Orion |
| DuckDuckGo | Existing normal and compatibility-gated private behavior, retained as a regression baseline |

Firefox Beta and Firefox ESR are not separate targets because their macOS distributions
are not reliably distinct, co-installable applications with independent identities.
Safari Beta and Chrome Extended Stable are likewise not separate application targets.

Each listed edition must have its own explicit descriptor. Bundle identifiers, profile
roots, executable paths, signing identities, application names, and private-mode flags
come from the installed official app bundle and a real launch probe. No value is inferred
from another channel or guessed from the visible application name. A descriptor is not
added until its values have been recorded in focused tests.

Official vendor sources are the only permitted download sources:

- [Safari Technology Preview](https://developer.apple.com/safari/technology-preview/)
- [Chrome release channels](https://support.google.com/chrome/a/answer/9300510)
- [Microsoft Edge Insider channels](https://www.microsoft.com/en-us/edge/download/insider)
- [Brave Beta and preview channels](https://brave.com/download-beta/)
- [Vivaldi downloads](https://vivaldi.com/download/)
- [Firefox desktop channels](https://www.mozilla.org/firefox/channel/)
- [Opera](https://www.opera.com/opera)
- [Arc](https://arc.net/)
- [Orion](https://orionbrowser.com/platforms/macos)

## Chosen Architecture

PickVia will keep explicit application descriptors and split browser identity from launch
behavior. `BrowserFamily` remains the persisted vendor/engine family identity and gains
new cases when needed for Opera, Arc, and Orion. A descriptor also declares three
non-persisted strategies:

1. **Profile strategy**: none, Chromium `Local State`, Firefox `profiles.ini`, Safari
   Shortcut helper, or a vendor-specific strategy proven by an installed-app probe.
2. **Launch strategy**: workspace URL open, Chromium command line, Firefox command line,
   DuckDuckGo coordinator, Safari Shortcut helper, or a vendor-specific adapter.
3. **Private strategy**: unsupported, Chromium incognito flag, Edge InPrivate flag,
   Firefox private-window flag, DuckDuckGo Fire coordinator, Safari Shortcut helper, or a
   vendor-specific mechanism proven by end-to-end testing.

The strategies are data carried by `BrowserDescriptor`; catalog and launcher code do not
infer behavior from a display name or assume that every Chromium-based product behaves
like Google Chrome.

Chrome, Edge, Brave, and Vivaldi editions may share a Chromium implementation only after
their exact profile root, executable, profile selector, private flag, and running-instance
behavior pass the same tests. Opera has its own family and descriptor even if its verified
adapter reuses Chromium parser or launcher components. Arc and Orion have dedicated
families so unsupported Chrome assumptions cannot leak into them.

## Capability Rules

Every descriptor produces a capability set from installed-app evidence. PickVia exposes
only targets backed by that set:

- A normal application-level target is the minimum support level for Opera, Arc, and
  Orion.
- A profile target appears only when PickVia can both discover a stable identity and
  direct an arbitrary URL to that exact profile.
- A private target appears only when PickVia can create or reuse a visibly private context
  and direct the requested URL into that context.
- A capability that fails after an app update becomes unavailable during rescan. A stored
  target is preserved as unavailable so the user's label, enabled state, and order are not
  silently lost.
- No selected profile or private target may degrade to a default profile, another edition,
  or a normal window.

The expected first-pass capability matrix is:

| Integration | Normal | Profiles | Private |
|---|---:|---:|---:|
| Safari and Safari Technology Preview | Yes | Shortcut proof gate | Shortcut proof gate |
| Chrome, Edge, Brave, and Vivaldi editions | Yes | Yes after edition-specific proof | Yes after edition-specific proof |
| Chromium | Existing behavior | Existing behavior | Existing behavior |
| Firefox editions | Yes | Yes after edition-specific proof | Yes after edition-specific proof |
| Opera | Yes | Only after Opera-specific proof | Only after Opera-specific proof |
| Arc | Yes | Only after Arc-specific proof | Only after Arc-specific proof |
| Orion | Yes | Only after Orion-specific proof | Only after Orion-specific proof |
| DuckDuckGo | Existing behavior | No | Existing compatibility-gated behavior |

“Proof gate” is an explicit product outcome, not an unimplemented placeholder. The
implementation phase starts with the relevant failing test and disposable real-app probe.
If the probe cannot meet the success criteria in this document, the descriptor declares
that capability unsupported and no target is generated.

## Discovery and Reconciliation

`BrowserCatalog` continues to resolve applications through Launch Services by exact
bundle identifier. For each installed descriptor it:

1. Resolves the current application URL.
2. Validates that the app bundle matches the descriptor evidence needed by its adapter.
3. Reads profile metadata through the descriptor's profile strategy.
4. Returns an explicit metadata status and capability set.
5. Generates only supported normal, profile, and private target candidates.
6. Reconciles candidates with persisted targets by canonical ID while preserving user
   labels, enabled state, order, and unavailable targets.

Channel-specific profile stores remain independent. Chrome Beta, Dev, and Canary never
reuse stable Chrome metadata. The same rule applies to Edge, Brave, Vivaldi, and Firefox
editions. Profile access remains opt-in through PickVia's existing folder-access flow;
adding descriptors does not expand filesystem access automatically.

Existing pre-channel target IDs remain stable. New targets use the existing canonical
format of bundle identifier, opaque profile identity, and mode. Adding enum cases must be
decode-compatible with current configurations, and malformed or unknown values continue
to fail through the existing configuration safety path.

## Launch Data Flow

For every routed web URL:

1. The routing coordinator dequeues one URL and presents the grouped chooser.
2. The selected target resolves its application and descriptor by canonical ID.
3. The launcher revalidates application availability, target availability, descriptor
   family, profile shape, and requested mode.
4. The descriptor's launch adapter creates a launch plan containing only the selected app,
   validated profile selector, requested mode, and URL.
5. The executor launches the exact target.
6. Any adapter error returns PickVia's recoverable launch failure and leaves the next FIFO
   item available for user action.

Opened URLs remain in memory only. They are not included in configuration, markers,
diagnostic logs, installer manifests, or test reports. Diagnostics may record browser
bundle ID, target mode, process ID, and a synthetic E2E token, but never the routed URL.

## Safari Private and Profile Research Gate

Safari is not treated as permanently normal-only. The implementation must first test the
permissionless App Intent boundary available on the installed macOS version.

The installed Safari 27 metadata exposes these discoverable intents:

- `CreateNewWindow` with an `isPrivate` Boolean;
- `OpenTabGroup`;
- `CreateNewTab`;
- `LoadURLInTab`.

Apple documents that another app may run an installed Shortcut through the Shortcuts URL
scheme or command-line tool. The design uses a companion Shortcut rather than private
framework linkage or Safari menu automation.

### Private helper candidate

The private helper creates a new Safari window with `isPrivate` set to true, obtains its
tab, and loads the Shortcut input URL into that tab. PickVia invokes the helper with
`/usr/bin/shortcuts`. The URL is supplied through a pipe or other verified memory-only
input path; it must not be placed in a temporary regular file, clipboard, command-line
argument, or logged Shortcuts URL.

The helper is imported once by the user. PickVia stores only its non-sensitive identifier
or configured name. It checks helper availability before generating the private target and
fails closed if the helper is absent, renamed, incompatible, or returns an error.

### Profile helper candidate

The profile candidate uses one explicitly configured helper per Safari profile. Each
helper binds to a Tab Group belonging to that profile, opens the group, creates a new tab,
and loads the memory-only input URL. PickVia stores the helper identity and a user-facing
profile label; it does not enumerate or inspect unrelated personal Shortcuts.

The real proof must establish that the helper always activates the selected profile even
when another Safari profile was most recently used, when Safari is already running, and
when no window for the selected profile is open.

Safari Technology Preview is tested separately. A stable-Safari result is not reused for
the preview edition because Apple documents that extension and automation delivery may
follow the system's selected Safari version.

### Explicitly rejected Safari approaches

- No Safari Web Extension or Safari app extension in this scope.
- No System Events, Accessibility, synthetic keyboard input, or menu clicks.
- No mutation of Safari's “Open Links With Profile” website rules.
- No temporary change to Safari's startup or private-browsing preferences.
- No private Safari framework calls or undocumented LinkServices invocation.
- No normal-window fallback after a private/profile failure.

If the Shortcut proof fails, Safari and/or Safari Technology Preview remains normal-only
and the E2E report records the tested limitation.

## Installation Workflow

The test machine is Apple Silicon and has limited free disk space, so downloads and
installation are staged and audited:

1. Inventory already-installed apps without altering them.
2. Resolve each missing edition from its official vendor page.
3. Download into a uniquely created temporary directory.
4. Record source URL, download time, artifact name, size, and SHA-256 for the local review
   report.
5. Verify the artifact is a valid DMG, PKG, ZIP, or signed app as appropriate.
6. Inspect the contained app's bundle ID, display name, executable, architecture, version,
   signing authority, and team identity before installation.
7. Install the missing app to `/Applications` under its official side-by-side name.
8. Re-read the installed app and verify it matches the inspected artifact.
9. Remove mounted images and temporary download artifacts after verification.

Existing application bundles are not overwritten merely to standardize versions. If an
official installer requires replacing an existing app or accepting a new license, stop at
that exact action for user confirmation. Browser application bundles remain installed
after E2E testing, as requested.

## Disposable Test Data

Real profile routing requires real vendor metadata. Tests create only clearly named
synthetic profiles, such as `PickVia E2E`, through supported browser UI or startup flows.

- Existing profile directories are never opened for content inspection, copied, renamed,
  or deleted.
- Synthetic profiles use localhost-only test pages and no accounts, imports, sync, saved
  passwords, extensions, or personal browsing.
- Shared profile indexes may gain and later remove the synthetic entry through the
  browser's supported profile-management flow.
- Cleanup removes only the synthetic profile and test windows created in this run.
- If ownership of a profile or window is ambiguous, cleanup stops and leaves it intact.

Safari tests similarly create a synthetic profile and Tab Group only if required for the
profile proof. They do not inspect or route into an existing Safari profile.

## Automated Test Strategy

Implementation follows red-green-refactor. Focused tests are written and observed failing
before production changes.

Automated coverage must include:

- exact descriptor order and identity for every listed edition;
- family, profile strategy, launch strategy, and private strategy mappings;
- channel-specific profile roots and executable paths;
- Chromium and Firefox profile parsing through existing fixtures and new channel cases;
- target generation for each capability combination;
- no profile/private targets for unsupported capability combinations;
- reconciliation preserving custom names, enabled state, sort order, and unavailable
  targets when an edition disappears or loses a capability;
- exact normal/profile/private launch plans for every adapter;
- rejection of unsupported bundle IDs, family mismatches, malformed profile selectors,
  unavailable helpers, and missing executables;
- Safari helper availability, memory-only input, timeout, malformed output, and fail-closed
  behavior;
- configuration decode and migration with new family cases;
- unchanged DuckDuckGo safety, mail routing, chooser grouping, keyboard interaction, and
  URL validation behavior.

The full Swift suite, warnings-as-errors build, formatting lint, diff check, packaged-app
build, smoke test, and code-signature verification run before native E2E.

## Real End-to-End Verification

An E2E harness starts a local HTTP server and issues one unique opaque token per test. The
token identifies the test request without placing a real browsing URL in logs.

For every installed application edition:

1. Rescan in the packaged PickVia app and confirm the correct browser group and targets.
2. Route a unique localhost URL through the normal application target.
3. Prove the request reached the local server from the selected application edition.
4. Where profiles are supported, create or select the synthetic profile, route a second
   unique URL, and prove the visible window belongs to that profile.
5. Where private mode is supported, route a third unique URL and prove the visible window
   is private through native UI plus process/adapter evidence.
6. Exercise the already-running-app path and a cold-launch path.
7. Close only the generated test window and repeat the route to catch instance-reuse bugs.
8. Confirm no normal window received a private request and no other edition received the
   URL.
9. Confirm PickVia requested no Accessibility permission and used no synthetic input.

Computer control is an external observer for visible browser name, profile indicator,
private indicator, and URL. It is not linked into or required by PickVia. Server receipt,
process identity, and UI observation are all required; a successful process exit, HTTP 200,
or visible window alone is insufficient.

The final report contains one row per application and capability with `PASS`, `FAIL`, or
`UNSUPPORTED`, the installed version, bundle ID, adapter, and concise evidence. A failed
or unsupported capability is not represented as product support.

## Error Handling

- Missing application: preserve stored targets as unavailable and show the existing
  recoverable launch error.
- Changed bundle identity or executable: reject the launch and require a successful
  rescan/compatibility update.
- Missing or damaged profile metadata: keep browser-level targets available where safe;
  do not invent profile targets.
- Profile access denied or revoked: use existing access-required/revoked presentation and
  leave pre-existing targets unavailable rather than repointing them.
- Unsupported private mechanism: omit the private candidate or preserve a previously
  stored target as unavailable.
- Safari helper missing, renamed, timed out, or failed: fail closed with no ordinary Safari
  open.
- Browser update changes behavior during E2E: record the exact version as failed and do not
  add or retain the affected capability descriptor.

## Documentation

After implementation, update the README and website capability table only for verified
support. Documentation lists editions explicitly enough that users can distinguish stable,
Beta, Dev, Canary, Nightly, and Snapshot apps.

Safari documentation explains the one-time Shortcut helper when that capability passes.
It does not call a Tab Group a Safari profile unless E2E proves the group reliably selects
that profile. Unsupported Arc, Orion, Opera, or Safari capabilities are stated plainly.

## Non-Goals

- Firefox Beta or ESR as separate co-installed targets
- Safari Beta or Chrome Extended Stable as separate targets
- heuristic recognition of arbitrary vendor channels
- Accessibility, System Events, synthetic keyboard/pointer input, or menu automation
- a Safari extension in this feature
- URL rules, rewriting, browser extensions, or sync
- reading content from existing browser profiles
- notarization, release tagging, GitHub publication, website deployment, or replacing the
  installed PickVia app without a separate user request

## Acceptance Criteria

The feature is ready for review when:

1. Every listed application is installed from an official source or the report explains a
   vendor/OS installation blocker.
2. Every installed edition has an explicit, tested descriptor.
3. Normal routing passes real E2E for every supported application.
4. Profile and private routing pass real E2E everywhere PickVia advertises them.
5. Safari profile/private targets appear only after their Shortcuts-only proof passes.
6. No requested URL is persisted or logged.
7. No existing profile content is inspected or removed.
8. All automated, packaged-app, and code-signature gates pass with fresh output.
9. The final capability report distinguishes pass, fail, and unsupported outcomes without
   optimistic fallbacks.
