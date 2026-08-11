# Active-Space Window Policy Design

**Date:** 2026-08-10
**Status:** Approved

## Problem

When macOS delivers an HTTP or HTTPS link to PickVia, the chooser initially appears on the
desktop where the link was triggered, but macOS can then switch to the desktop containing an
open PickVia Settings or Welcome window.

Initial lifecycle instrumentation established this event order:

1. `applicationWillBecomeActive`
2. `applicationDidBecomeActive`
3. `application(_:open:)`
4. chooser presentation

Launch Services therefore activates the PickVia application before PickVia receives the URL.
The chooser already uses `.moveToActiveSpace`, but it is not the window driving the activation.
The ordinary Settings or Welcome window is. Making only the chooser nonactivating cannot prevent
the later Space transition.

The user approved moving an open PickVia Settings or Welcome window to the current desktop behind
the chooser.

Follow-up instrumentation after the first implementation exposed a second, later race. A SwiftUI
Welcome window can become main before AppKit reports it visible. The notification callback queued
an asynchronous main-actor task, and the shared policy then rejected the window because it was no
longer visible after chooser presentation hid ordinary surfaces. In the reproduced failure, the
chooser was on the current desktop and the unprepared Welcome window retained its old-Space
behavior; 354 milliseconds later macOS switched desktops. The correction must therefore prepare a
newly main ordinary window synchronously, before visibility and chooser state can change.

## Goals

- Triggering a link must not switch away from the desktop where the link was triggered.
- Any visible ordinary PickVia window may move to the active desktop and remain behind the chooser.
- The chooser must retain its current pointer-based placement, keyboard handling, and
  nonactivating-panel behavior.
- Existing window collection behaviors unrelated to Spaces must be preserved.
- The behavior must be covered by automated lifecycle and window-policy tests plus a real
  two-desktop regression check.

## Non-Goals

- Preserve the original Space assignment of Settings or Welcome windows.
- Hide, close, or recreate Settings or Welcome when a link arrives.
- Change the user's global Mission Control or Spaces settings.
- Introduce a background URL-handler helper process or cross-process IPC.
- Change browser routing, profile discovery, default-browser registration, or chooser content.

## Chosen Approach

Add a small AppKit window-space coordinator that applies `.moveToActiveSpace` to ordinary PickVia
windows. The coordinator handles two lifecycle boundaries:

1. When an ordinary PickVia window becomes main, it receives the policy immediately.
2. In `applicationWillBecomeActive`, all currently visible ordinary PickVia windows receive the
   policy again before macOS completes application activation.

Applying the policy at both boundaries covers windows created by SwiftUI after launch once they
become main and windows that were already open on another Space when a link was triggered. The
operation is idempotent. The main-window notification path must run synchronously on the main
thread and must not require the window to be visible, because SwiftUI can post the lifecycle
notification immediately before ordering the window onscreen. The activation scan remains limited
to visible windows.
Because AppKit reports the incoming URL only after activation begins, this is an intrinsic policy
for ordinary PickVia windows: they may move to the current desktop on any PickVia activation, not
only link delivery.

### Eligible Windows

The coordinator applies the policy to normal application surfaces such as Settings and Welcome.
For the activation scan it excludes windows that are not visible. For the synchronous main-window
notification it permits a not-yet-visible ordinary window so the policy is installed before
ordering. Both paths exclude:

- `NSPanel` instances, including the chooser, profile-access panel, and About panel
- sheets
- non-normal-level windows such as status-bar infrastructure

Filtering by AppKit window role avoids depending on localized titles or private SwiftUI window
identifiers. Future ordinary PickVia windows will inherit the same active-Space behavior.

### Preserving Existing Behavior

The coordinator removes `.canJoinAllSpaces`, if present, because it conflicts with the chosen
single-Space movement policy. It then inserts `.moveToActiveSpace` into the remaining
`collectionBehavior` rather than replacing the entire option set. This preserves unrelated
behaviors such as Mission Control participation. Panels are excluded so their specialized
`.transient`, `.canJoinAllSpaces`, and full-screen behaviors remain unchanged.

## Components

### `AppWindowSpaceCoordinator`

A focused AppKit component will:

- receive the application window list through an injected provider
- determine whether a window is an eligible ordinary PickVia surface
- add `.moveToActiveSpace` to eligible windows
- observe `NSWindow.didBecomeMainNotification` on the main queue and synchronously apply the same
  policy to newly main eligible windows, including windows not yet visible
- remove its notification observer during teardown

The component will not know about URLs, routing, chooser models, or SwiftUI destinations.

### `AppDelegate`

`AppDelegate` will own the coordinator and call it from `applicationWillBecomeActive`. URL delivery
continues through the existing `application(_:open:)` implementation without reordering or delay.

### `ChooserPanelController`

No additional Space workaround is added. Its existing `.nonactivatingPanel`,
`.moveToActiveSpace`, order-front, and key-window behavior remains the chooser-specific policy.

## Event Flow

1. When SwiftUI makes Settings or Welcome main, the main-queue observer synchronously installs the
   active-Space policy, even if the window is not visible yet.
2. A link is triggered on Desktop A while that ordinary window is assigned to Desktop B.
3. Launch Services begins activating PickVia.
4. `applicationWillBecomeActive` asks the coordinator to prepare all visible ordinary PickVia
   windows again.
5. AppKit calls `application(_:open:)` with the URL.
6. PickVia presents the chooser on Desktop A at the pointer-selected screen.
7. Any Settings or Welcome window that is shown remains behind the chooser on Desktop A instead of
   pulling macOS to Desktop B.
8. Selection or cancellation follows the existing routing lifecycle.

## Failure Handling

Applying a window collection behavior is synchronous and nonthrowing. If no ordinary window exists
during activation, the coordinator performs no work; the main-window observer applies the policy
if SwiftUI creates a main window later. The observer executes synchronously on the main queue rather
than scheduling a task, so later visibility changes cannot invalidate the decision. Repeated
application is safe and must not alter URL data or persist window contents.

No diagnostic logging of URLs will be added. The temporary activation instrumentation used during
root-cause analysis is not part of the implementation.

## Testing

### Automated Tests

- An ordinary normal-level `NSWindow` gains `.moveToActiveSpace`.
- Existing unrelated collection behaviors remain present.
- An `NSPanel` is not modified.
- A non-normal-level infrastructure window is not modified.
- A not-yet-visible newly main eligible window receives the policy synchronously through the
  notification boundary.
- The activation-wide scan continues to ignore hidden windows.
- `AppDelegate.applicationWillBecomeActive` asks the coordinator to prepare existing windows.
- Existing chooser regression tests continue to verify that the chooser itself does not activate
  PickVia and cannot become the main window.

Implementation follows red-green-refactor: each new behavior is first demonstrated by a failing
test, followed by the smallest production change that passes it.

### Manual Two-Desktop Regression

1. Open PickVia Settings on Desktop B.
2. Switch to Desktop A and trigger an HTTP or HTTPS link.
3. Confirm the desktop remains Desktop A throughout presentation.
4. Confirm Settings moved to Desktop A behind the chooser.
5. Confirm keyboard selection, mouse selection, and Escape still work.
6. Repeat with the Welcome window open on Desktop B.
7. Repeat with no ordinary PickVia window open.

## Verification Gate

Before replacing the running app:

- run focused coordinator and AppDelegate tests
- run the full test suite with warnings treated as errors
- run Swift formatting checks and `git diff --check`
- build the production app bundle
- run the bundle smoke test and strict code-signature verification
- complete the two-desktop regression above using the rebuilt app
