# Browser Editions and New Families Implementation Plan

> **For implementation:** Use `using-git-worktrees`, `test-driven-development`,
> `systematic-debugging`, and `verification-before-completion`. Execute this plan in order
> and stop at every explicit evidence gate; a failed real-browser probe becomes
> `UNSUPPORTED`, never an optimistic implementation.

**Goal:** Install the approved official browser matrix, add descriptor-driven PickVia
support for each verified application, and prove normal, profile, and private routing in
the packaged app wherever the installed browser exposes a stable, permissionless route.

**Architecture:** Move discovery and launch behavior out of `BrowserFamily` switches and
into explicit per-application descriptors. Each descriptor declares independent profile,
launch, and private strategies. Opera, Arc, and Orion receive separate persisted family
identities. Safari profile/private support is a Shortcuts-only proof gate with memory-only
URL input; failed proof leaves that capability unavailable. Existing target IDs and user
customizations remain stable through reconciliation.

**Tech stack:** Swift 6, Swift Testing, SwiftPM, AppKit/NSWorkspace, `Process`, macOS
Shortcuts CLI, vendor-signed macOS apps, zsh, Python 3 localhost probe server, `codesign`,
`spctl`, `hdiutil`, and external Computer Use observation.

---

## File map

### Core model and behavior

- Create `Sources/PickViaCore/Discovery/BrowserDescriptor.swift`: descriptor and the three
  strategy enums.
- Modify `Sources/PickViaCore/Models/BrowserModels.swift`: add Opera, Arc, and Orion family
  cases.
- Modify `Sources/PickViaCore/Models/RouteModels.swift`: persist an optional adapter/helper
  identifier without persisting launch paths or URLs.
- Modify `Sources/PickViaCore/Discovery/BrowserCatalog.swift`: consume descriptor
  strategies, generate only proven targets, and reconcile lost capabilities safely.
- Modify `Sources/PickViaCore/ProfileAccess/ProfileRootValidator.swift`: validate the
  descriptor's profile strategy rather than its family.
- Modify `Sources/PickViaCore/Launching/BrowserLauncher.swift`: build plans from explicit
  launch/private strategies rather than engine assumptions.
- Create `Sources/PickViaCore/Launching/SafariShortcutRouter.swift` only if the Safari
  proof gate passes.
- Create `Sources/PickViaCore/Launching/SafariShortcutVerifier.swift` only if the Safari
  proof gate passes; it owns a one-shot loopback listener used while saving a helper.

### App and settings

- Modify `Sources/PickVia/App/AppModel.swift`: derive profile-access rows and manual-target
  validity from descriptor capabilities.
- Modify `Sources/PickVia/ProfileAccess/ProfileAccessFolderSelector.swift`: show the
  descriptor-specific metadata marker and root.
- Modify `Sources/PickVia/Views/BrowserSettingsView.swift`: show only supported profile and
  private choices; add Safari helper configuration only if the proof passes.
- Modify `Sources/PickVia/Services/SystemServices.swift`: compose a real Shortcuts process
  runner only if the proof passes.

### Tests and test tooling

- Create `Tests/PickViaCoreTests/BrowserDescriptorTests.swift`.
- Modify `Tests/PickViaCoreTests/BrowserCatalogTests.swift`.
- Modify `Tests/PickViaCoreTests/BrowserLauncherTests.swift`.
- Modify `Tests/PickViaCoreTests/ProfileRootValidatorTests.swift`.
- Modify `Tests/PickViaCoreTests/ConfigStoreTests.swift`.
- Modify `Tests/PickViaTests/AppModelTests.swift`.
- Modify `Tests/PickViaTests/ProfileAccessFolderSelectorTests.swift`.
- Modify `Tests/PickViaTests/BrowserSettingsViewTests.swift`.
- Create `Tests/PickViaCoreTests/SafariShortcutRouterTests.swift` only if the Safari proof
  passes.
- Create `Tests/PickViaCoreTests/SafariShortcutVerifierTests.swift` only if the Safari
  proof passes.
- Create `scripts/browser-e2e/inspect-browser-app.sh`: read-only app identity/signature
  inventory.
- Create `scripts/browser-e2e/localhost_probe.py`: localhost-only opaque-token receiver
  that never logs a URL.

### Evidence and documentation

- Create `docs/testing/browser-app-inventory-2026-08-21.md`: official download and
  installed-app evidence.
- Create `docs/testing/browser-compatibility-2026-08-21.md`: `PASS`, `FAIL`, and
  `UNSUPPORTED` E2E matrix.
- Modify `README.md`: only capabilities that pass real E2E.
- Modify `site/index.html`: mirror the verified browser matrix without publishing it.

---

## Task 0: Isolate the work and establish a clean baseline

**Files:** No production files.

- [ ] **Step 1: Create a feature worktree without disturbing the user's current checkout**

Follow `using-git-worktrees` and create a `feature/browser-editions-and-families` branch;
this repository's pre-commit policy rejects reserved automation prefixes.
Before creation, verify the repository status and ensure the already committed design
`14211b1` is the base. Do not stage the existing untracked `.agents/` directory or
unrelated plan files.

- [ ] **Step 2: Record baseline toolchain and tests**

Run:

```zsh
swift --version
sw_vers
uname -m
swift test --disable-sandbox
xcrun swift-format lint --recursive Sources Tests
git diff --check
```

Expected: the full suite, formatter, and whitespace checks pass before feature edits. If
they do not, use `systematic-debugging` and distinguish a pre-existing failure from a
feature failure before continuing.

- [ ] **Step 3: Record the non-destructive installed-browser baseline**

Run read-only Launch Services and app-bundle inventory for Safari, DuckDuckGo, Chrome,
Chrome Beta, Chromium, Edge, Brave, Vivaldi, and Firefox. Record which apps already exist;
do not launch a browser or inspect profile contents in this step.

---

## Task 1: Download, inspect, and install the official application matrix

**Files:**

- Create: `scripts/browser-e2e/inspect-browser-app.sh`
- Create: `docs/testing/browser-app-inventory-2026-08-21.md`

- [ ] **Step 1: Write the failing inspection-script contract**

Create shell-level assertions in a temporary test directory for an app fixture with an
`Info.plist`. The script must reject a non-`.app` path, a missing executable, a non-arm64
binary, and an unsigned bundle. Its successful output must contain only these keys:

```text
path bundle_id display_name executable version architectures team_id authorities sha256
```

Run the assertions before the script exists and confirm RED.

- [ ] **Step 2: Implement the read-only inspector**

Use `/usr/libexec/PlistBuddy`, `file`, `codesign -dvvv`, `codesign --verify --deep
--strict`, `spctl --assess --type execute`, and `shasum -a 256`. Never traverse browser
profile roots. Re-run the shell assertions and confirm GREEN.

- [ ] **Step 3: Resolve downloads from vendor-owned pages only**

For each missing application, resolve and record the final vendor URL before downloading:

- Safari Technology Preview
- Chromium, from the official Chromium snapshot infrastructure
- Google Chrome Dev and Canary
- Microsoft Edge Stable, Beta, Dev, and Canary
- Brave Beta and Nightly
- Vivaldi Stable and Snapshot
- Firefox Developer Edition and Nightly
- Opera, Arc, and Orion

Stable Chrome, Chrome Beta, Brave, Firefox, DuckDuckGo, system Safari, and Chromium remain
inventory rows; resolve any one that is missing. Firefox Beta/ESR, Safari Beta, and Chrome
Extended Stable remain excluded.

- [ ] **Step 4: Stage and verify each artifact before installation**

Use one `mktemp -d` directory. For every DMG, PKG, ZIP, or app:

1. record source URL, retrieval time, filename, byte size, and SHA-256;
2. verify container integrity;
3. mount or expand without executing the browser;
4. inspect app name, bundle ID, executable, architecture, version, authorities, and team
   ID;
5. compare the signing identity with the vendor evidence;
6. append the result to the inventory report.

If a package requires accepting a new EULA or replacing an existing application, stop at
that exact action and ask the user. Do not overwrite an installed browser automatically.

- [ ] **Step 5: Install side by side and re-verify**

Copy or install each verified app under its official distinct name in `/Applications`.
Run the inspector against the installed path and require its identity and executable hash
to match the staged artifact. Keep all browser apps installed after E2E. Unmount images
and remove only the unique temporary download directory.

- [ ] **Step 6: Freeze descriptor evidence**

Complete one inventory row per approved app with exact installed values. These values,
not assumptions from another edition, are the source of truth for Tasks 3-5. Commit the
inspector and inventory report:

```zsh
git add scripts/browser-e2e/inspect-browser-app.sh docs/testing/browser-app-inventory-2026-08-21.md
git commit -m "test: record official browser application inventory"
```

---

## Task 2: Introduce descriptor-driven strategies without changing behavior

**Files:**

- Create: `Sources/PickViaCore/Discovery/BrowserDescriptor.swift`
- Create: `Tests/PickViaCoreTests/BrowserDescriptorTests.swift`
- Modify: `Sources/PickViaCore/Discovery/BrowserCatalog.swift`
- Modify: `Sources/PickViaCore/ProfileAccess/ProfileRootValidator.swift`
- Modify: `Sources/PickViaCore/Launching/BrowserLauncher.swift`
- Modify: `Tests/PickViaCoreTests/BrowserCatalogTests.swift`
- Modify: `Tests/PickViaCoreTests/BrowserLauncherTests.swift`
- Modify: `Tests/PickViaCoreTests/ProfileRootValidatorTests.swift`

- [ ] **Step 1: Add failing strategy-mapping tests for the nine existing descriptors**

Define the intended non-persisted types in tests:

```swift
public enum BrowserProfileStrategy: Equatable, Sendable {
  case none
  case chromium(root: String)
  case firefox(root: String)
  case safariShortcut
}

public enum BrowserLaunchStrategy: Equatable, Sendable {
  case workspace
  case chromium(executableRelativePath: String, profileArgument: String)
  case firefox(executableRelativePath: String)
  case duckDuckGo
}

public enum BrowserPrivateStrategy: Equatable, Sendable {
  case unsupported
  case argument(String)
  case duckDuckGoFire
  case safariShortcut
}
```

Update `BrowserDescriptor` to be expected to carry `profileStrategy`,
`launchStrategy`, and `privateStrategy`; remove `profileRoot` and
`executableRelativePath` expectations from callers. Existing mappings are:

- Safari: `.none`, `.workspace`, `.unsupported`
- DuckDuckGo: `.none`, `.duckDuckGo`, `.duckDuckGoFire`
- Chrome, Chrome Beta, Chromium, Brave, Vivaldi: Chromium profile/launch and
  `--incognito`
- Edge Stable: Chromium profile/launch and `--inprivate`
- Firefox: Firefox profile/launch and `-private-window`

Run:

```zsh
swift test --disable-sandbox --filter BrowserDescriptorTests
swift test --disable-sandbox --filter BrowserLauncherTests
swift test --disable-sandbox --filter ProfileRootValidatorTests
```

Expected: RED because the types and descriptor fields do not exist and Edge currently
inherits Chrome's private flag.

- [ ] **Step 2: Move and implement the descriptor model**

Move `BrowserDescriptor` out of `BrowserCatalog.swift`. Add computed properties for
`profileRoot`, `requiredProfileMarker`, `executableRelativePath`, `supportsProfiles`, and
`supportsPrivateMode`, all derived from the three strategies. Keep the supported
descriptor order unchanged in this refactor.

- [ ] **Step 3: Refactor discovery and validation by profile strategy**

Make `BrowserCatalog.readProfiles` switch on `descriptor.profileStrategy`:

- `.none` and `.safariShortcut`: `.notApplicable` unless configured helpers are supplied
  later;
- `.chromium`: read `Local State` and call `ChromiumProfileParser`;
- `.firefox`: read `profiles.ini` and call `FirefoxProfileParser`.

Change `BrowserProfileRootValidator.requiredMarker` to accept a descriptor or profile
strategy. Remove family-based marker decisions from `AppModel` and
`ProfileAccessFolderSelector`.

- [ ] **Step 4: Refactor launch planning by descriptor strategies**

Keep the existing trusted-app and trusted-executable validation. Generate the normal plan
from `launchStrategy`; generate private arguments only from `privateStrategy`. Reject:

- a profile when `supportsProfiles` is false;
- private mode when `supportsPrivateMode` is false;
- a Firefox profile lacking an absolute `profileLaunchPath`;
- an app/family/descriptor mismatch;
- missing or non-executable trusted paths.

Do not add Safari Shortcuts execution yet.

- [ ] **Step 5: Prove behavior parity and the Edge correction**

Re-run the focused suites. Add explicit assertions that Edge private uses `--inprivate`,
Chrome uses `--incognito`, Firefox uses `-private-window`, and normal workspace launches
contain no private/profile fields. Then run the full suite.

- [ ] **Step 6: Format, inspect, and commit the refactor**

```zsh
xcrun swift-format format --in-place Sources/PickViaCore/Discovery/BrowserDescriptor.swift Sources/PickViaCore/Discovery/BrowserCatalog.swift Sources/PickViaCore/ProfileAccess/ProfileRootValidator.swift Sources/PickViaCore/Launching/BrowserLauncher.swift Tests/PickViaCoreTests/BrowserDescriptorTests.swift Tests/PickViaCoreTests/BrowserCatalogTests.swift Tests/PickViaCoreTests/BrowserLauncherTests.swift Tests/PickViaCoreTests/ProfileRootValidatorTests.swift
xcrun swift-format lint --recursive Sources Tests
git diff --check
git add Sources/PickViaCore Tests/PickViaCoreTests
git commit -m "refactor: make browser behavior descriptor driven"
```

---

## Task 3: Add every verified Chrome, Edge, Brave, Vivaldi, and Firefox edition

**Files:**

- Modify: `Sources/PickViaCore/Discovery/BrowserDescriptor.swift`
- Modify: `Tests/PickViaCoreTests/BrowserDescriptorTests.swift`
- Modify: `Tests/PickViaCoreTests/BrowserCatalogTests.swift`
- Modify: `Tests/PickViaCoreTests/BrowserLauncherTests.swift`
- Modify: `Tests/PickViaCoreTests/ConfigStoreTests.swift`

- [ ] **Step 1: Add failing exact-matrix descriptor tests**

Assert this display order:

```text
Safari
Safari Technology Preview
DuckDuckGo
Google Chrome
Google Chrome Beta
Google Chrome Dev
Google Chrome Canary
Chromium
Microsoft Edge
Microsoft Edge Beta
Microsoft Edge Dev
Microsoft Edge Canary
Brave Browser
Brave Beta
Brave Nightly
Vivaldi
Vivaldi Snapshot
Firefox
Firefox Developer Edition
Firefox Nightly
```

For the channel entries in this task, assert the exact bundle ID, family, profile root,
required marker, executable path, normal launch strategy, profile selector, and private
argument copied from Task 1's installed-app evidence. Do not fill a field by changing an
edition suffix on another descriptor.

- [ ] **Step 2: Observe RED, then add only verified descriptors**

Run `swift test --disable-sandbox --filter BrowserDescriptorTests`. Add Safari Technology
Preview and the missing Chrome, Edge, Brave, Vivaldi, and Firefox channel descriptors.
If any official app could not be installed or does not have a distinct identity, omit its
descriptor and mark its inventory row blocked; do not alias it to another edition.

- [ ] **Step 3: Test channel-isolated discovery**

For every descriptor with profiles, inject a file system containing only that edition's
metadata root. Assert the catalog reads exactly its root and produces its own application
ID. Add a negative test proving stable metadata is not used when a channel root is absent.

- [ ] **Step 4: Test exact per-edition launch plans**

For every installed descriptor, use the trusted resolver and executable validator to
assert the exact executable and arguments for normal, `PickVia E2E` profile, and private
targets. Add a cross-edition rejection test: a target for one bundle ID must never launch
another edition's executable.

- [ ] **Step 5: Test persisted-family compatibility**

Add config fixtures that decode old `.safari`, `.duckDuckGo`, `.chromium`, and `.firefox`
families unchanged. Add round-trip coverage for all new descriptors without changing
existing target IDs.

- [ ] **Step 6: Run, format, and commit**

```zsh
swift test --disable-sandbox --filter BrowserDescriptorTests
swift test --disable-sandbox --filter BrowserCatalogTests
swift test --disable-sandbox --filter BrowserLauncherTests
swift test --disable-sandbox --filter ConfigStoreTests
xcrun swift-format lint --recursive Sources Tests
git diff --check
git add Sources/PickViaCore Tests/PickViaCoreTests
git commit -m "feat: add verified browser channel editions"
```

---

## Task 4: Build the privacy-preserving localhost E2E receiver

**Files:**

- Create: `scripts/browser-e2e/localhost_probe.py`
- Create or modify: `docs/testing/browser-compatibility-2026-08-21.md`

- [ ] **Step 1: Add failing receiver tests**

Test that the receiver binds only to `127.0.0.1`, accepts only a generated opaque token,
returns `204`, rejects unknown paths, records token/time/remote loopback address, and does
not emit the request URL or headers. Confirm a second request is independently observable.

- [ ] **Step 2: Implement the minimal receiver**

Use Python's standard library `http.server`. Disable default request logging. Generate
tokens with `secrets.token_urlsafe(24)`. Keep the token registry and receipts in memory;
write only the final token result when explicitly requested by the harness.

- [ ] **Step 3: Prove localhost-only and no-URL logging**

Run the receiver, make one expected and one unexpected request with `curl`, and assert the
captured output contains no `http://`, query string, header, or full path. Commit:

```zsh
git add scripts/browser-e2e/localhost_probe.py
git commit -m "test: add private browser routing receiver"
```

---

## Task 5: Add Opera, Arc, and Orion as fail-closed families

**Files:**

- Modify: `Sources/PickViaCore/Models/BrowserModels.swift`
- Modify: `Sources/PickViaCore/Discovery/BrowserDescriptor.swift`
- Modify: `Sources/PickViaCore/Discovery/BrowserCatalog.swift`
- Modify: `Sources/PickViaCore/Launching/BrowserLauncher.swift`
- Modify: `Sources/PickViaCore/Config/ConfigStore.swift`
- Modify: `Tests/PickViaCoreTests/BrowserDescriptorTests.swift`
- Modify: `Tests/PickViaCoreTests/BrowserCatalogTests.swift`
- Modify: `Tests/PickViaCoreTests/BrowserLauncherTests.swift`
- Modify: `Tests/PickViaCoreTests/ConfigStoreTests.swift`

- [ ] **Step 1: Add failing family and minimum-capability tests**

Add `.opera`, `.arc`, and `.orion` to expected `BrowserFamily` coding. Initially expect
each verified descriptor to provide `.workspace` normal launch, `.none` profiles, and
`.unsupported` private. Assert each produces exactly one normal browser-level target and
rejects profile/private targets. Extend the exact descriptor-order test from Task 3 by
appending Opera, Arc, and Orion in that order.

- [ ] **Step 2: Add the three explicit descriptors and persisted cases**

Use Task 1's installed bundle evidence. Keep the three family cases distinct even where a
browser's engine is Chromium. Run config round-trip and malformed-family recovery tests.

- [ ] **Step 3: Probe enhanced capabilities with disposable data**

For one browser at a time, create a `PickVia E2E` profile through the browser's supported
UI or documented CLI. Test candidate profile selectors and private arguments in cold,
running, and closed-window states against the localhost receiver. Require all three:

1. correct installed app/process identity;
2. visible correct profile/private UI;
3. receipt of that test's opaque token.

Never inspect existing profile contents. Never infer Arc or Orion behavior from Chromium.

- [ ] **Step 4: Promote only capabilities that pass**

For each passing capability, first add a failing unit test with the exact installed
adapter values, then update that descriptor strategy. For a failed probe, keep
`.none`/`.unsupported` and add the evidence as `UNSUPPORTED` to the compatibility report.
There is no fallback to browser default or normal mode.

- [ ] **Step 5: Verify disappearing and downgraded capabilities**

Add reconciliation tests proving custom label, enabled state, and sort order survive when
an app disappears or an enhanced capability is later removed, while the affected stored
target becomes unavailable.

- [ ] **Step 6: Run, format, and commit**

```zsh
swift test --disable-sandbox --filter BrowserDescriptorTests
swift test --disable-sandbox --filter BrowserCatalogTests
swift test --disable-sandbox --filter BrowserLauncherTests
swift test --disable-sandbox --filter ConfigStoreTests
xcrun swift-format lint --recursive Sources Tests
git diff --check
git add Sources/PickViaCore Tests/PickViaCoreTests
git commit -m "feat: add Opera Arc and Orion routing"
```

---

## Task 6: Make target generation and Settings capability-driven

**Files:**

- Modify: `Sources/PickViaCore/Discovery/BrowserCatalog.swift`
- Modify: `Sources/PickVia/App/AppModel.swift`
- Modify: `Sources/PickVia/ProfileAccess/ProfileAccessFolderSelector.swift`
- Modify: `Sources/PickVia/Views/BrowserSettingsView.swift`
- Modify: `Tests/PickViaCoreTests/BrowserCatalogTests.swift`
- Modify: `Tests/PickViaTests/AppModelTests.swift`
- Modify: `Tests/PickViaTests/ProfileAccessFolderSelectorTests.swift`
- Modify: `Tests/PickViaTests/BrowserSettingsViewTests.swift`

- [ ] **Step 1: Add failing capability-combination tests**

Cover all combinations: normal-only, normal+private, normal+profiles, and all three.
Assert target candidates and Add Target controls expose exactly those capabilities. A
family name must not control the UI.

- [ ] **Step 2: Replace Safari/family special cases**

Replace checks such as `family == .safari`, `family == .firefox`, and grouped
`.chromium/.firefox` availability decisions with descriptor properties or explicit
profile-strategy checks. Retain Firefox identity migration only inside the Firefox profile
strategy.

- [ ] **Step 3: Preserve browser-level safety with inaccessible metadata**

Assert access-required, revoked, absent, and damaged metadata leave only safe
browser-level targets available, while profile targets are preserved unavailable. Add one
test per strategy rather than one per family.

- [ ] **Step 4: Verify profile-access rows**

Only descriptors with file-backed profile strategies may show a folder grant row. The row
must use that descriptor's exact expected root and marker. Normal-only and Safari
Shortcut descriptors must not request broad disk access.

- [ ] **Step 5: Run app and core tests, then commit**

```zsh
swift test --disable-sandbox --filter BrowserCatalogTests
swift test --disable-sandbox --filter AppModelTests
swift test --disable-sandbox --filter ProfileAccessFolderSelectorTests
swift test --disable-sandbox --filter BrowserSettingsViewTests
xcrun swift-format lint --recursive Sources Tests
git diff --check
git add Sources/PickViaCore Sources/PickVia Tests/PickViaCoreTests Tests/PickViaTests
git commit -m "refactor: drive browser targets from capabilities"
```

---

## Task 7: Run the Safari Shortcuts proof gate

**Files:**

- Append: `docs/testing/browser-compatibility-2026-08-21.md`
- Conditional create: `Sources/PickViaCore/Launching/SafariShortcutRouter.swift`
- Conditional create: `Sources/PickViaCore/Launching/SafariShortcutVerifier.swift`
- Conditional create: `Tests/PickViaCoreTests/SafariShortcutRouterTests.swift`
- Conditional create: `Tests/PickViaCoreTests/SafariShortcutVerifierTests.swift`
- Conditional modify: `Sources/PickViaCore/Models/RouteModels.swift`
- Conditional modify: `Sources/PickViaCore/Discovery/BrowserDescriptor.swift`
- Conditional modify: `Sources/PickViaCore/Discovery/BrowserCatalog.swift`
- Conditional modify: `Sources/PickViaCore/Launching/BrowserLauncher.swift`
- Conditional modify: `Sources/PickVia/Views/BrowserSettingsView.swift`
- Conditional modify: `Sources/PickVia/Services/SystemServices.swift`
- Conditional modify: `Tests/PickViaCoreTests/ConfigStoreTests.swift`
- Conditional modify: `Tests/PickViaCoreTests/BrowserCatalogTests.swift`
- Conditional modify: `Tests/PickViaCoreTests/BrowserLauncherTests.swift`
- Conditional modify: `Tests/PickViaTests/BrowserSettingsViewTests.swift`

- [ ] **Step 1: Create only synthetic Safari test state**

With the user's visible confirmation, create a Safari profile and Tab Group named
`PickVia E2E`. Do not enumerate, open, or modify unrelated profiles or Shortcuts. Build a
private helper and a per-profile helper using Safari's installed App Intents:
`CreateNewWindow(isPrivate)`, `OpenTabGroup`, `CreateNewTab`, and `LoadURLInTab`.

- [ ] **Step 2: Prove memory-only CLI input before testing routing**

Invoke the explicitly named helper with:

```zsh
set +x
printf '%s' "$pickvia_e2e_url" | /usr/bin/shortcuts run 'PickVia Safari Private' --input-path /dev/stdin
unset pickvia_e2e_url
```

The receiver supplies `pickvia_e2e_url` in memory immediately before this command; never
print it and never enable shell tracing. Inspect `lsof`, the
process arguments, clipboard state, and the temporary directory. The URL must not appear
in a regular file, command argument, Shortcuts URL scheme, clipboard, or report. If
`/dev/stdin` is copied to persistent storage or is unsupported, stop and record Safari
private/profile as `UNSUPPORTED`.

- [ ] **Step 3: Prove private behavior in all required states**

Test cold Safari, running Safari, a different active profile, and a closed generated
private window. Require the exact Safari process, visible Private indicator, and receiver
token. Confirm no normal window receives the request and no Accessibility prompt appears.

- [ ] **Step 4: Prove profile behavior in all required states**

Test the `PickVia E2E` helper while another Safari profile was last used, with no E2E
window, and after closing/reopening the generated window. Require the visible selected
profile/Tab Group and receiver token. A Tab Group alone is not evidence of profile
selection.

- [ ] **Step 5: Repeat the proof separately for Safari Technology Preview**

Do not reuse stable Safari evidence. If the App Intent opens stable Safari, mark the
Technology Preview profile/private capabilities `UNSUPPORTED` and retain its normal
workspace target.

- [ ] **Step 6A: If a capability fails, encode the negative result**

Keep the descriptor strategy `.unsupported`/`.none`, add unit coverage that no target is
generated, and record the tested macOS/browser versions and failing criterion. Do not add
System Events, Accessibility, synthetic input, an extension, private framework calls, or
a normal fallback.

- [ ] **Step 6B: If a capability passes, implement the smallest helper adapter test-first**

Persist only a user-entered helper name/identifier in
`BrowserTargetOptions.adapterIdentifier`; give the initializer a default of `nil`, encode
only non-`nil` values, and decode a missing key as `nil`. Add
`LaunchPlan.safariShortcut(identifier:url:)` and a `SafariShortcutRouting` dependency.
`SystemSafariShortcutRouter` must launch `/usr/bin/shortcuts` with arguments containing
only the helper identifier and `/dev/stdin`, write the URL bytes to a pipe, close the pipe,
enforce a bounded timeout, and map every failure to `LaunchFailure`. Tests must prove the
URL is absent from arguments and diagnostics, missing identifiers fail closed, timeout
terminates the helper process, and no workspace fallback occurs.

Add a focused Safari Settings form that accepts a helper identifier and user-facing
profile label. `SafariShortcutVerifier` starts a one-shot `127.0.0.1` listener, creates an
opaque token in memory, invokes only that named helper through the router, and creates the
target only after the listener receives the token before its timeout. A private binding
creates a browser-level private target with `adapterIdentifier`; a profile binding creates
a normal target whose opaque `profileIdentity` is derived from the helper identifier and
whose `adapterIdentifier` holds the launch binding. Neither flow calls `shortcuts list` or
inspects unrelated personal Shortcuts.

- [ ] **Step 7: Run conditional tests and commit the evidence/result**

```zsh
swift test --disable-sandbox --filter SafariShortcutRouterTests
swift test --disable-sandbox --filter SafariShortcutVerifierTests
swift test --disable-sandbox --filter BrowserLauncherTests
swift test --disable-sandbox --filter BrowserCatalogTests
swift test --disable-sandbox --filter ConfigStoreTests
swift test --disable-sandbox --filter BrowserSettingsViewTests
xcrun swift-format lint --recursive Sources Tests
git diff --check
git add Sources Tests docs/testing/browser-compatibility-2026-08-21.md
git commit -m "feat: gate Safari routing through verified Shortcuts"
```

If no Safari helper capability passes, omit nonexistent conditional source/test files and
use `test: record Safari Shortcuts compatibility limits` as the commit message.

---

## Task 8: Run fresh automated and packaged-app gates

**Files:** Existing production and test files only.

- [ ] **Step 1: Run all automated checks from a clean build**

```zsh
swift package clean
swift test --disable-sandbox
swift build -c release --disable-sandbox -Xswiftc -warnings-as-errors
xcrun swift-format lint --recursive Sources Tests
git diff --check
```

Expected: zero failures, zero warnings, and no whitespace errors.

- [ ] **Step 2: Build and smoke-test the packaged app**

```zsh
zsh scripts/build-app.sh
zsh scripts/smoke-test.sh
codesign --verify --deep --strict --verbose=4 build/PickVia.app
spctl --assess --type execute --verbose=4 build/PickVia.app
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' build/PickVia.app/Contents/Info.plist
```

Expected: build and smoke test pass, the deep signature verifies, Gatekeeper output is
recorded accurately for the existing ad-hoc signature, and bundle ID is
`dev.bozhenpeng.PickVia`.
Do not replace `/Applications/PickVia.app`.

- [ ] **Step 3: Audit privacy and capability assumptions**

```zsh
rg -n "NSAppleEventsUsageDescription|NSAccessibility|System Events|shortcuts list|--incognito|--inprivate|-private-window|profileRoot|requiredProfileMarker" Support Sources Tests
rg -n "print\(|NSLog|os_log|Logger|absoluteString" Sources/PickViaCore Sources/PickVia
git status --short
```

Inspect every match. Confirm no routed URL is logged or persisted, no Accessibility or
Apple Events permission was added, and private flags occur only in explicit descriptors
or tests.

---

## Task 9: Run the real packaged-app E2E matrix

**Files:**

- Modify: `docs/testing/browser-compatibility-2026-08-21.md`

- [ ] **Step 1: Prepare disposable profiles**

Create only `PickVia E2E` profiles through supported browser flows. Do not sign in, sync,
import, add extensions, or inspect existing profile contents. Record the synthetic
profile's opaque selector and only the minimum visible label needed for verification.

- [ ] **Step 2: Verify discovery in `build/PickVia.app`**

Launch the packaged build without installing it over the user's app. Rescan and confirm
every installed edition appears as the correct distinct PickVia browser group, with only
the capabilities its descriptor advertises.

- [ ] **Step 3: Test normal routing for every installed edition**

For each app, route a unique localhost token through PickVia. Test cold launch,
already-running, and repeat after closing the generated window. Require receiver receipt,
exact app/process identity, and visible app edition.

- [ ] **Step 4: Test every advertised profile target**

Route a fresh token to `PickVia E2E`; require receipt plus visible profile identity. Keep a
different edition/profile running to prove there is no cross-edition reuse.

- [ ] **Step 5: Test every advertised private target**

Route a fresh token; require receipt plus visible private indicator and adapter/process
evidence. Confirm no normal window and no other edition receives the request.

- [ ] **Step 6: Record one result per app and capability**

For every matrix cell record `PASS`, `FAIL`, or `UNSUPPORTED`, installed version, bundle
ID, strategy, cold/running/reopen result, server token receipt, visible evidence, and any
limitation. A single required-state failure makes the capability `FAIL` and removes it
from product support until fixed.

- [ ] **Step 7: Clean only unambiguous synthetic state**

Close generated windows and remove only `PickVia E2E` profiles/helpers whose ownership is
certain, using the browser's supported UI. If ownership is ambiguous, leave the item and
report it. Keep browser applications installed. Do not inspect or delete any other data.

---

## Task 10: Reconcile failures and publish only truthful local documentation

**Files:**

- Modify as evidence requires: `Sources/PickViaCore/Discovery/BrowserDescriptor.swift`
- Modify as evidence requires: relevant focused tests
- Modify: `README.md`
- Modify: `site/index.html`
- Finalize: `docs/testing/browser-compatibility-2026-08-21.md`

- [ ] **Step 1: Remove any capability that failed real E2E**

First add a regression test reproducing the false-positive target or launch plan. Change
the descriptor to `.none` or `.unsupported`, keep stored targets unavailable, and re-run
the focused and full suites. Do not weaken E2E criteria.

- [ ] **Step 2: Update support copy from the final report**

List installed editions explicitly. Claim profile/private support only where the report
says `PASS`. Explain the one-time Safari helper only if its real proof passed. State Opera,
Arc, Orion, or Safari limitations plainly.

- [ ] **Step 3: Re-run final verification after documentation changes**

```zsh
swift test --disable-sandbox
swift build -c release --disable-sandbox -Xswiftc -warnings-as-errors
xcrun swift-format lint --recursive Sources Tests
git diff --check
zsh scripts/build-app.sh
zsh scripts/smoke-test.sh
codesign --verify --deep --strict --verbose=4 build/PickVia.app
```

- [ ] **Step 4: Inspect the final scope and commit**

```zsh
git status --short
git diff --stat HEAD
git diff -- README.md site/index.html docs/testing/browser-compatibility-2026-08-21.md
git add Sources Tests scripts/browser-e2e README.md site/index.html docs/testing/browser-compatibility-2026-08-21.md
git commit -m "test: verify expanded browser compatibility"
```

Stage only files created or modified by this plan. Do not commit downloaded installers,
browser profiles, `.agents/`, build products, or unrelated plans.

- [ ] **Step 5: Stop at the local review boundary**

Report the commit list, automated evidence, packaged-app evidence, installed browser list,
full E2E matrix, and any retained synthetic state. Do not tag a release, push to GitHub,
deploy the website, replace `/Applications/PickVia.app`, or publish artifacts without a
separate user request.

---

## Plan-wide invariants

- Official vendor artifacts only; preserve and never overwrite existing browser apps
  without exact confirmation.
- No inspection of existing browser-profile contents.
- No URL persistence or URL logging.
- No profile/private fallback to browser default, normal mode, or another edition.
- No Safari extension, Accessibility, System Events, synthetic input, or private API.
- No capability is added before a failing unit test and a passing real-app probe.
- Browser applications remain installed; only unambiguous `PickVia E2E` data is removed.
- All publication and replacement actions remain out of scope.
