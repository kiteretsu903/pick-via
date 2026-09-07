# DuckDuckGo Browser Support Design

Updated 2026-09-06: compatibility and recovery simplification. Original browser research below is historical evidence for 1.203.0; it is not a new E2E result for the revised implementation.

## Goal

PickVia will recognize the official DuckDuckGo browser for macOS and expose two
browser-level targets:

- `DuckDuckGo` opens a URL through the user's ordinary DuckDuckGo state.
- `DuckDuckGo Private` opens a URL in a real DuckDuckGo Fire Window backed
  by a separate, PickVia-managed process and disposable browser state.

The Fire path must not require Accessibility permission, an installed browser
extension, clipboard use, synthetic keyboard or pointer input, or a change to
the user's DuckDuckGo preferences. Existing browsers and stored routes must
remain unchanged.

## Validated Mechanism

DuckDuckGo does not publish a Fire Window command-line flag, URL scheme, or
AppleScript dictionary. Its current macOS source does provide the primitives
needed for a permissionless application-level route:

- the `startup-window-type` preference accepts `fire-window` and is converted
  to a burner startup mode;
- launching without a URL creates a window from that startup mode;
- reopening a running, windowless app also uses the startup mode;
- the standard `GURL` Apple event opens an external URL in an existing window;
- when an external URL arrives with no window, DuckDuckGo otherwise creates a
  regular window.

This means PickVia must launch the isolated process without a URL, establish a
Fire Window first, and target subsequent reopen and URL events to that exact
process. A bundle-level `open` is insufficient because Launch Services may
deliver the URL to another DuckDuckGo instance.

The mechanism was validated locally against the official direct-download
DuckDuckGo 1.203.0 build. A duplicate process started with an isolated home and
the Fire startup preference fetched a PID-targeted localhost URL while the
ordinary DuckDuckGo process remained separate.

Relevant upstream behavior is documented in DuckDuckGo's
[`StartupPreferences.swift`](https://github.com/duckduckgo/apple-browsers/blob/1.203.0%2Bmacos/macOS/DuckDuckGo/Preferences/Model/StartupPreferences.swift),
[`AppDelegate.swift`](https://github.com/duckduckgo/apple-browsers/blob/1.203.0%2Bmacos/macOS/DuckDuckGo/Application/AppDelegate.swift), and
[`URLEventHandler.swift`](https://github.com/duckduckgo/apple-browsers/blob/1.203.0%2Bmacos/macOS/DuckDuckGo/Application/URLEventHandler.swift).

## Catalog and Target Model

Add an explicit DuckDuckGo descriptor:

- display name: `DuckDuckGo`
- bundle identifier: `com.duckduckgo.macos.browser`
- family: a new DuckDuckGo browser family
- profile root: none
- executable path: none for ordinary routing

DuckDuckGo has no PickVia-visible profile list. Catalog reconciliation creates
one normal browser-level target and, when the installed build supports safe
isolation, one private-mode target whose generated label is
`DuckDuckGo Private`. The UI deliberately uses the same ordinary private-target
naming as Firefox and Chromium-family browsers. The existing persisted
`private` mode remains the storage identity, so no new mode or
configuration-schema migration is required; only the underlying launch
mechanism is DuckDuckGo-specific.

The normal target is enabled by default. The private target follows the
existing browser-level private-target default. User edits to names, enabled
state, and sort order survive rescans through the existing canonical target
IDs.

## Compatibility Boundary

Normal discovery and routing do not validate DuckDuckGo's signature, pin a
publisher, or require private-mode compatibility. They still resolve the expected
browser and distinguish ordinary processes from PickVia-managed private ones.
An unreadable private-build metadata record leaves the ordinary browser available.

Private routing reads the bundle identifier and sandbox entitlement only. There is
no version allowlist or version parsing. Reading entitlement metadata does not
validate code signatures. Sandboxed or unknown-sandbox builds cannot use this
disposable-home implementation. Rescans preserve unavailable private-target
customization.

The internal preference layout remains an implementation dependency. A private
failure never opens the link through an ordinary window. No real browser profile
is modified or shared.

## Ordinary DuckDuckGo Routing

PickVia must keep managed Fire processes out of the ordinary route:

1. Resolve the trusted DuckDuckGo application by its exact bundle identifier.
2. If an unmanaged DuckDuckGo process is already running, send the URL event to
   that PID.
3. Otherwise launch a new ordinary instance with the URL and the user's normal
   environment.
4. Activate the exact ordinary process through `NSRunningApplication`.

PickVia does not read or edit the user's DuckDuckGo profile. DuckDuckGo retains
control of which existing user window receives an ordinary external URL; in
particular, PickVia will not synthesize input to override a user-created Fire
window that is already active in the ordinary process.

## Fire Process Coordinator

Introduce an actor-backed DuckDuckGo process coordinator and inject it into the
browser launcher behind a small protocol. The actor serializes duplicate
launches, tracks the managed PID, and prevents normal and Fire requests from
racing into the wrong instance.

For a Fire request, the coordinator:

1. Resolves the expected DuckDuckGo application and checks private compatibility.
2. Creates a uniquely named, PickVia-owned directory below the user's cache
   directory with owner-only permissions.
3. Atomically seeds only the isolated DuckDuckGo preferences needed to mark
   onboarding complete, disable session restoration, and set
   `startup-window-type` to `fire-window`.
4. Launches DuckDuckGo with `NSWorkspace.OpenConfiguration`,
   `createsNewApplicationInstance = true`, the isolated directory as
   `CFFIXED_USER_HOME`, and state restoration disabled. No URL is included in
   this launch.
5. Waits for the returned `NSRunningApplication` to finish launching within a
   bounded timeout.
6. Sends a PID-targeted reopen Apple event. This is a no-op while the Fire
   Window exists and recreates a Fire Window from the startup preference after
   the last one was closed.
7. Sends the PID-targeted `GURL` event only after the reopen event has been
   accepted, then activates that exact process.

The coordinator reuses one managed process while it remains valid. Before each
URL it repeats the reopen-then-URL sequence, so closing the last Fire Window
does not cause the next route to become a regular isolated window.

Both Apple events use the do-not-prompt option. If macOS would require user
consent, PickVia returns a launch failure without presenting an Automation or
Accessibility prompt. It never retries through keyboard shortcuts, menu
automation, a bundle-level URL open, or the ordinary target.

## Managed State and Cleanup

The isolated home contains only state produced by the PickVia-managed
DuckDuckGo process. It never contains the user's ordinary bookmarks, history,
cookies, autofill data, or preferences. Fire Windows therefore behave as real
DuckDuckGo Fire Windows but do not share ordinary DuckDuckGo personalization.

Each new session has one atomically replaced `Session.json` journal with a
`pending` or `managed` state. Both contain the UUID, application/executable paths,
and available exact launch identity; neither contains the routed URL. Pending
state is durable before launching and is updated with the returned PID and launch
time. Committing managed state replaces pending state in the same file, so a
second marker removal is not part of a successful launch. A reported commit
failure restores pending state before attempting rollback.

The store still reads legacy `Process.json` and `Quarantine.json` pairs. New
journals supersede legacy files in the same UUID directory. A malformed journal
never falls back to a legacy record. Corrupt/missing legacy ownership and unsafe
files are treated as opaque, rather than allowing their process to be reused as
ordinary. Legacy conflicting records retain the original session-wide ownership
rules: a stale quarantine cannot delete a same-session live managed process.

A managed process is reusable only when its PID, exact launch time, bundle ID,
and canonical application/executable paths match. These are process-ownership
checks, not signature checks. A managed private session can be reused across
links and PickVia restarts. It is not a fresh identity on every click.

Startup maintenance, browser-process exit notifications, and routes share one
serialized recovery path. Unknown ownership forces an ordinary route to create
a fresh ordinary instance without enumerating ambient processes for reuse.
Unrelated opaque sessions do not prevent reuse of a positively identified managed
private session. If the ownership store cannot be read, normal browsing can still
launch a fresh ordinary instance; private routing stops. A failed deletion of a
proven-stale directory preserves its records for retry and does not block either
route. No unknown process is killed or reclassified merely to make cleanup pass.

State files have mode 0600 and session directories mode 0700. Deletion remains
restricted to UUID descendants of the PickVia cache root, using held no-follow
directory descriptors, inode/device identity checks, and a temporary rename.
Authority files are removed last. Failed deletion restores the canonical session
name when possible. New and legacy sessions share the same deletion implementation.

PickVia does not terminate managed browser processes when PickVia exits. While
PickVia runs, a DuckDuckGo process-exit notification triggers cleanup after checking
ownership and staleness again. Missed notifications are covered by startup and
subsequent routing. Closing a window without exiting the browser process does not
remove its home. Opaque state and failed deletion can retain files, so disposable
state does not imply an immediate wipe or memory-only storage.

## Launch and Error Semantics

The browser launch plan gains a DuckDuckGo Fire case containing the trusted app
URL and requested web URL. Ordinary DuckDuckGo remains a distinct launch path.
All profile-bearing DuckDuckGo targets are rejected.

The chooser keeps its existing recoverable error behavior for:

- an incompatible or changed DuckDuckGo build;
- isolated preference creation or atomic-write failure;
- duplicate-process launch or readiness timeout;
- process exit during routing;
- PID identity mismatch;
- Apple-event delivery failure, including consent-required errors `-1743`/`-1744`.

The sender checks both transport failures and the AppleEvent reply error number.
Known permission, readiness, response-timeout, activation, and compatibility errors
reach the chooser as fixed, actionable text. Arbitrary reply messages, URLs, and
filesystem paths remain sanitized. Event timeouts and activation failures remind
the user to check browser windows before retrying because delivery may have occurred.
Permission prompts remain suppressed; PickVia does not silently change permissions.

No Fire error may degrade to an ordinary DuckDuckGo launch. URLs are passed in
memory to the target process and are not written to coordinator markers or
logs. A non-sensitive diagnostic log may record only the target PID and
Apple-event type so packaged-app verification can correlate the route with the
intended process.

## Test Strategy

Unit and integration coverage will establish that:

- the catalog contains the exact DuckDuckGo descriptor and new family;
- discovery creates no profiles and generates `DuckDuckGo` plus
  `DuckDuckGo Private` only for a compatible build;
- rescans preserve custom target state and mark a no-longer-compatible private
  target unavailable;
- ordinary routing excludes every managed PID and never uses the isolated
  environment;
- the preference seeder writes the exact isolated paths and values and never
  touches the real home;
- duplicate launch uses a new application instance, the isolated environment,
  no startup URL, and a bounded readiness wait;
- reopen precedes `GURL`, both events target the returned PID, and both prohibit
  consent prompts;
- the coordinator reuses a valid process, rejects a reused or mismatched PID,
  and limits cleanup to stale coordinator-owned directories;
- sandboxed/unknown-sandbox, profile-bearing, unavailable,
  and Apple-event failure cases do not silently fall back to ordinary routing;
- normal discovery and routing do not depend on private compatibility metadata;
- atomic journal transitions, legacy recovery, corruption, delayed deletion,
  process-exit cleanup, and chooser error sanitization have regression coverage;
- Safari, Chromium-family browsers, Firefox, mail routing, configuration
  decoding, and chooser behavior retain their existing tests.

## Real End-to-End Verification

After the automated suite, formatting lint, and packaged-app smoke test pass,
test the exact built `PickVia.app` with the installed DuckDuckGo build. Do not run
strict signature verification. Native browser checks are recorded separately from
automated tests:

1. Rescan applications and confirm the two DuckDuckGo labels.
2. Route a unique localhost URL through `DuckDuckGo`; prove the request arrives
   and the ordinary process is not a managed Fire PID.
3. Route another unique localhost URL through `DuckDuckGo Private`;
   correlate the coordinator's PID-only event log, the WindowServer owner PID,
   and the received request, then inspect the UI with the external
   computer-control harness to confirm the visible Fire Window indicator and
   URL.
4. Close only the generated test Fire Window, route a third unique URL, and
   confirm the same managed process reopens a Fire Window before loading it.
5. Confirm the user's ordinary DuckDuckGo data root and preferences were not
   modified by the Fire route.
6. Confirm PickVia itself never requests Accessibility or Automation consent.

Computer control is an external acceptance-test observer; its permissions are
not used by, linked into, or required by the shipped PickVia mechanism. Test
cleanup may burn only the coordinator-owned synthetic Fire session. It must not
close or alter the user's ordinary DuckDuckGo windows or profile.

## Documentation

Update the README browser list and capability table. Document that DuckDuckGo
has no PickVia profile selector, that its private target uses a real Fire Window
with separate disposable state, and that Fire support is limited to a
compatible unsandboxed build within the documented release family. Do not claim that ordinary
DuckDuckGo bookmarks, autofill, extensions, or preferences are available inside
the managed Fire Window.

## Non-goals

- Accessibility-driven menu or shortcut automation
- synthetic keyboard or pointer events
- a companion DuckDuckGo extension
- modification of the user's DuckDuckGo preferences or data container
- profile selection inside DuckDuckGo
- Fire support for sandboxed Mac App Store builds
- a generic integration for arbitrary WebKit browsers
- release tagging, pushing, notarization, or publication
