# PickVia Dedicated E2E Automation Build Design

## Status

Approved interactively on 2026-08-22. This design unblocks the real browser matrix after
external Computer Use could identify PickVia's transient chooser rows but could not
reliably dispatch their SwiftUI actions.

## Problem

PickVia presents a borderless non-activating chooser panel. The panel intentionally
cancels when it resigns key status. External automation introduces a focus/tool boundary
between URL delivery and selection, so the chooser may disappear before a semantic click.
Even a synchronized Computer Use click could report success without proving that the row's
SwiftUI action dispatched.

Direct routing to the exact installed Microsoft Edge application succeeded with the
localhost receiver, exact process identity, and visible edition evidence. The observed
blocker is therefore the external control boundary around PickVia's transient chooser,
not Edge readiness or the core browser launch path.

The automation must exercise the packaged application after target selection without
adding Accessibility, System Events, AppleScript, Screen Recording, simulated input, or a
release-build control surface.

## Goals

- Automate exact chooser selection in a separately compiled E2E application.
- Keep all automation code and control strings absent from ordinary debug and release
  PickVia binaries.
- Exercise the real application composition after selection: `AppModel`,
  `RoutingCoordinator`, trusted target resolution, `BrowserLauncher`, and system process
  launch.
- Preserve the harness privacy contract: routed URLs never enter the E2E app or helper
  arguments/environment, status messages, harness output, task-root regular files, or
  clipboard. The helper receives the route only over stdin and delivers it to the E2E app
  as an open event.
- Fail closed on every missing, ambiguous, unavailable, disabled, or mismatched target.
- Keep the E2E application, configuration, status channel, and cleanup independent from
  the installed PickVia application.

## Non-goals

- Shipping dormant automation in normal PickVia builds.
- Replacing the chooser's existing unit and WindowServer-backed UI coverage.
- Adding a general remote-control, scripting, URL-scheme, or IPC API to PickVia.
- Making PickVia the system default during E2E.
- Inspecting or reporting unrelated browser profiles, pages, Shortcuts, or personal data.
- Restoring Safari profile/private work; Safari and Safari Technology Preview remain
  normal-workspace-only by user decision.
- Installing the unsigned Chromium snapshot.

## Approaches considered

### Dedicated compile-time E2E chooser driver — selected

A separate build injects an exact-target chooser driver at application composition time.
It receives only synthetic target identity and expected capability metadata, renders the
real chooser presentation, validates the target, and invokes the existing selection
callback. This avoids external focus races while retaining the production routing stack
after selection.

### Core-only command-line harness — rejected as primary evidence

A CLI linked to `PickViaCore` would be simpler and useful for diagnosis, but it would
bypass packaged application composition and would not prove the app's URL intake and
routing coordinator path.

### macOS UI automation — rejected

XCUITest, Accessibility, System Events, AppleScript, Screen Recording, or simulated input
would reintroduce focus flakiness and broaden permissions around visible personal browser
state. They are unnecessary once selection can be injected before the transient panel
loses key status.

## Build isolation

Add `scripts/build-e2e-app.sh` to compile the executable with a dedicated Swift condition,
for example `PICKVIA_E2E_AUTOMATION`. It packages the result separately as
`build-e2e/PickVia E2E.app` with a distinct bundle identifier such as
`dev.bozhenpeng.PickVia.E2E`.

The existing `scripts/build-app.sh`, normal Swift builds, release artifacts, and installed
`/Applications/PickVia.app` remain unchanged. The E2E build is never installed or made the
default handler. URL delivery explicitly names its full application path.

All automation types, environment-key literals, and selection wiring live behind the
compile-time condition. A normal-binary inspection gate verifies that those symbols and
strings are absent rather than merely inactive.

## Components

### E2E control specification

At E2E-app launch, the harness supplies only:

- an exact canonical target ID;
- the expected browser bundle identifier;
- the expected route mode;
- an opaque session nonce;
- an isolated PickVia configuration-directory path; and
- a task-owned status FIFO path.

These values may be inherited through environment variables because none contains the
routed URL or a human profile label. The target must refer only to task-created synthetic
state. Controls are immutable for the lifetime of one E2E app process; the app is
relaunched when the target changes.

### E2E chooser presenter

Under `PICKVIA_E2E_AUTOMATION`, application composition wraps the ordinary
`ChooserPanelController` in an E2E-only `ChooserPresenting` implementation.

For each web request it:

1. asks the ordinary chooser to build/render the real presentation;
2. validates the control specification;
3. finds exactly one target whose canonical ID, application bundle identifier, and mode
   match the control;
4. requires the target to be web-capable, enabled, and available;
5. schedules selection on the main actor without crossing an external tool boundary; and
6. invokes the existing `onSelection` callback with that exact target ID.

The wrapper does not call `BrowserLauncher` directly and does not construct a fallback
target. The existing coordinator owns dismissal, launch, queue advancement, and sanitized
error recovery.

One immutable target control can select repeated requests for cold, already-running, and
closed/reopen checks. Selection is at most once per request identifier.

### Isolated application state

The E2E build resolves PickVia's configuration, profile-access bookmarks, and preferences
under a unique task-owned directory instead of the user's ordinary PickVia support
directory. Its distinct bundle identifier also separates `UserDefaults` and LaunchServices
identity.

The browser catalog still reads the real supported browser metadata necessary to discover
targets. The harness never emits unrelated profile labels or paths. Only exact synthetic
`PickVia E2E` selectors created through supported browser flows are eligible for controls.

### Status channel

The app writes exactly one initial newline-delimited sanitized status record per request
to the supplied FIFO. Only an initial `selected` may be followed by exactly one
`launch-error`; no other second record is valid. Allowed outcomes are the closed set:

- `selected`;
- `control-missing`;
- `control-malformed`;
- `target-missing`;
- `target-ambiguous`;
- `target-disabled`;
- `target-unavailable`;
- `target-browser-mismatch`;
- `target-mode-mismatch`;
- `target-shape-mismatch`;
- `non-web-request`;
- `launch-error`.

Records contain the session nonce and safe outcome only. They never contain a URL, token
path, profile label, filesystem path, arbitrary error text, or a serialized target.
Writing the status must be bounded and must not block application routing indefinitely if
the FIFO reader disappears.

## Route data flow

1. The harness starts the one-shot `127.0.0.1` receiver and keeps its route in memory.
2. It launches the exact E2E application with synthetic control metadata and an isolated
   support directory.
3. The existing exact-app helper receives the route over stdin and asks `NSWorkspace` to
   deliver it to `PickVia E2E.app`; the URL never appears in helper arguments.
4. `AppDelegate` passes the URL to the production `AppModel.accept` path.
5. `RoutingCoordinator` asks the E2E chooser wrapper to present the current target
   snapshot.
6. The wrapper validates and selects the exact target through the existing callback.
7. The production `RouteLauncher` and `BrowserLauncher` resolve and launch the installed
   browser.
8. The browser requests the localhost route, and the receiver records the opaque token.
9. The harness independently verifies exact browser process identity and the required
   edition/profile/private evidence.

## Failure behavior

- A missing or malformed compile-time control causes no selection.
- Zero or multiple target matches cause no selection.
- Disabled, unavailable, mail, wrong-application, wrong-mode, or profile-shape mismatches
  cause no selection.
- The E2E presenter never substitutes browser default, normal mode, another edition, or a
  similarly named profile.
- Status-channel failure never enables routing and cannot turn a rejected control into a
  selection.
- Every receiver, application, browser process, and helper has a bounded supervisor.
- Browser-process snapshots are authoritative: enumeration or identity-query failures
  fail closed, and only a confirmed disappeared-PID race may be skipped. An unknown
  snapshot never proves absence, ownership, or successful cleanup.
- Harness/control failures are reported separately from browser/product failures. They do
  not justify removing a capability unless the real production route itself fails after
  selection.

## Test-driven implementation

Production changes begin only after focused tests fail because the E2E chooser and build
variant do not exist.

Unit coverage must prove:

- exactly one matching enabled/available web target is selected;
- selection occurs at most once per request;
- repeated requests for the same controlled target are selected independently;
- missing, malformed, duplicate, disabled, unavailable, mail, wrong-browser, wrong-mode,
  and structurally incompatible targets are rejected;
- rejection invokes neither the requested target nor any fallback target;
- status output is drawn from the closed outcome set and contains no URL or arbitrary
  target/profile text;
- the ordinary chooser remains the production composition when the compile condition is
  absent; and
- isolated support-directory resolution exists only in the E2E composition.

Build coverage must prove:

- the normal release binary contains no E2E automation symbol, marker, or environment-key
  string;
- the E2E binary has the distinct bundle identifier and an explicit automation marker;
- both app bundles pass their applicable smoke and strict codesign checks; and
- the E2E app is created only under `build-e2e/` and is never copied to `/Applications`.

## Real integration gate

Before the full matrix, Microsoft Edge Stable normal routing must pass in all three states:

- cold launch;
- already-running; and
- after closing and reopening the generated browser window/process as defined by the
  matrix protocol.

Each state requires a fresh receiver token, exact Edge process identity, an E2E status of
`selected`, and sanitized visible edition evidence. The full browser matrix begins only
after this pilot passes.

The subsequent matrix retains the existing rules:

- all installed editions receive normal-route coverage;
- every advertised file-backed profile target uses only a task-created `PickVia E2E`
  profile;
- every advertised private target requires a receiver receipt and independent private
  evidence;
- Safari enhanced cells remain `UNSUPPORTED` by user decision;
- Chromium remains `UNSUPPORTED`/not installed because it failed the signing gate; and
- a failed required state fails that capability without borrowing evidence from another
  edition.

The harness boundary ends when production routing hands the URL to the selected browser.
Depending on its existing strategy, `BrowserLauncher` may use target-browser arguments,
an AppleEvent, or `NSWorkspace`; the target browser may persist ordinary history or state.
Those production/browser behaviors are intentionally outside the harness privacy guarantee
and are not redesigned by this E2E work.

## Privacy and audit requirements

- Never emit a raw chooser/accessibility tree.
- Never print or persist the routed URL, request path, query, or headers in harness output
  or the task-owned support root.
- Never put the URL in the driver, E2E app, or helper arguments/environment, status
  records, harness logs, task-root regular files, or clipboard. The stdin/open-event path
  is the sole harness delivery channel.
- Production `BrowserLauncher` delivery to the selected target browser, including browser
  arguments, AppleEvents, `NSWorkspace`, and browser-owned persistence, is outside this
  harness-specific guarantee.
- Tokens may appear in the sanitized compatibility ledger, but the route assembled from
  them may not.
- Record only version, bundle ID, strategy, exact process identity, bounded state,
  receipt result, sanitized visible observation, and cleanup result.
- Do not enumerate or report unrelated profiles. Existing user browser processes are
  preserved unless an exact reversible test step is separately authorized.

## Cleanup

After each cell, terminate only exact task-owned browser/helper/receiver processes and
remove only exact task-owned FIFOs and temporary roots. After the matrix:

- terminate the E2E app;
- remove `build-e2e/PickVia E2E.app` only if cleanup of generated build artifacts is
  desired; otherwise leave it ignored and report it;
- remove the isolated E2E PickVia support directory;
- remove only synthetic browser profiles whose ownership is certain through supported
  browser flows;
- restore the installed PickVia process to its pre-test running/stopped state;
- verify no receiver, FIFO writer, helper, E2E app, or task browser process remains; and
- leave ambiguous state untouched and document it.

## Acceptance criteria

The design is complete when:

1. the dedicated E2E build can select an exact target without external UI automation;
2. normal/release PickVia binaries contain no E2E automation code or control strings;
3. the Edge Stable three-state pilot passes through the packaged E2E app;
4. the real installed-browser matrix runs with the established privacy and fail-closed
   rules;
5. all automated, release, package, signature, privacy, and cleanup gates pass; and
6. the compatibility report distinguishes product failures, unsupported capabilities,
   and harness failures truthfully.
