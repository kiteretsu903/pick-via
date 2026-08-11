# Chooser Latency Optimization Design

**Date:** 2026-08-10
**Status:** Stage 1 implemented; Stage 2 abandoned

**Implementation scope:** Stage 1 chooser prewarming only.

## Decision Update — 2026-08-10

The proposed runtime conditional Welcome `Scene` was abandoned after a test-first investigation.
The installed SwiftUI SDK explicitly makes the general `SceneBuilder.buildOptional` overload
unavailable: runtime `if` statements in a `SceneBuilder` may only be used with `#available`
clauses. The requested conditional `Window` consequently failed at `PickViaApp.body` with
`failed to produce diagnostic for expression`; wrapping it in `Group` failed identically. A
`#available` version split cannot provide a macOS 14 fallback within `SceneBuilder`. The user chose
to retain Stage 1 only; no Stage 2 source or test changes exist.

## Problem

PickVia's chooser has a noticeable delay after the user clicks an HTTP or HTTPS link. Controlled
instrumentation separated PickVia's work from Launch Services and WindowServer timing:

- On a fresh chooser presentation, URL delivery reached PickVia about 113 milliseconds after the
  probe began. Model preparation took less than 1 millisecond, while constructing and laying out
  the SwiftUI chooser took about 50-60 milliseconds and ordering the panel took about 4-7
  milliseconds.
- On a reused chooser panel, URL delivery reached PickVia after about 70 milliseconds, model
  preparation remained negligible, rendering took about 18-21 milliseconds, and ordering took
  less than 1 millisecond.
- External visibility measurements were about 192-209 milliseconds for a fresh presentation. The
  external probe over-reported reused-panel latency by roughly 300 milliseconds relative to
  PickVia's own completion timestamp, so WindowServer visibility is not a reliable app-side
  benchmark by itself.
- Disabling panel animation produced only noise-level changes and is not an optimization target.

The controllable first-use cost is therefore SwiftUI panel and hosting-view initialization, not URL
validation, routing, browser-status refresh, or chooser-model construction. A completed onboarding
session can also cause SwiftUI to create a Welcome scene that immediately has no content and
dismisses itself. That unnecessary ordinary-window lifecycle work shares the activation path with
the chooser. Existing Welcome-scene behavior remains unchanged.

## Goals

- Move chooser panel and SwiftUI initialization out of the first ordinary link presentation.
- Preserve routing, chooser content, keyboard and pointer behavior, default-browser checks, and the
  active-Space fix.
- Keep macOS 14 as the minimum supported version.
- Improve the controlled, app-side fresh-presentation path by at least 25 milliseconds after
  prewarming has completed. The expected improvement is approximately 30-40 milliseconds from
  panel prewarming.
- Keep the adopted change testable and reversible.

## Non-Goals

- Promise an instantaneous chooser or eliminate Launch Services and WindowServer latency.
- Optimize model work that measures below 1 millisecond.
- Add a background URL broker, helper application, IPC, or persistent daemon.
- Add arbitrary launch delays to guess whether a URL is about to arrive.
- Change onboarding requirements or prevent incomplete onboarding from displaying Welcome.
- Persist or log URL contents for performance measurement.
- Change global Mission Control, Spaces, or animation settings.

## Considered Approaches

### 1. Panel prewarming — adopted

Create the real chooser panel and lay out a representative `ChooserView` after launch, without
ordering it onscreen or starting a presentation. This directly targets the measured work, works on
macOS 14, preserves existing onboarding behavior, and is independently measurable and reversible.

### 2. Conditional Welcome registration — investigated and abandoned

SwiftUI's macOS 14 `SceneBuilder` does not support a general runtime conditional scene. Its general
`buildOptional` overload is unavailable outside `#available` clauses, so the proposed conditional
Welcome `Window` cannot compile for the supported deployment target. The user declined a macOS 15
version split, timer, or AppKit replacement; this approach was not implemented.

### 3. Suppress all ordinary scenes or add a background URL broker

SwiftUI's `defaultLaunchBehavior(.suppressed)` directly controls automatic scene presentation, but
it is available only on macOS 15 and later. An AppKit-managed Welcome window or a separate URL
broker could provide more control on every supported system, but either would add significantly
more lifecycle state and testing than the evidence justifies. They are excluded from this change.

## Final Architecture

The adopted optimization is one measured Stage 1 change. It retains the existing Welcome-scene
lifecycle and adds only chooser prewarming after a successful ordinary launch.

### Stage 1: Idempotent chooser prewarming

`ChooserPanelController` gains a focused `prepare(applications:targets:)` operation. The operation
will:

1. Return immediately if the panel and hosting view already exist.
2. Read the current URL-visibility and density preferences so the prewarmed view uses the same
   shape as the next presentation.
3. Build a private, representative `ChooserPresentation` from the current browser applications and
   targets plus a constant non-user URL under the reserved `.invalid` domain.
4. Run the existing render and layout path to create the `NSHostingView<ChooserView>` and `NSPanel`.
5. Clear the temporary presentation state while retaining the hosting view and unordered panel for
   reuse.

Prewarming must not order the panel, make it key, install the key monitor, capture the pointer,
invoke selection or cancellation callbacks, report an active presentation, or call
`onPresentationChange`. `hasActivePresentation` must remain false throughout. The representative
URL is constant, exists only in memory, and is replaced by the first real request; no user URL is
recorded or persisted.

A narrow `ChooserPrewarming` protocol exposes the operation to composition without widening
`ChooserPresenting`, whose responsibility remains user-visible routing. Production composition
returns the model, profile-access presenter, and chooser prewarmer together. `AppDelegate` owns the
prewarmer and schedules one closure on the next main-run-loop turn after
`applicationDidFinishLaunching`. At execution time, that closure passes the model's current
applications and targets to `prepare`.

Scheduling keeps launch completion responsive for a menu-bar app. If a link arrives before the
scheduled work, the normal lazy presentation path remains correct. Both paths execute on the main
actor, and `prepare` is idempotent, so the queued prewarm becomes a no-op if real presentation won
the race. For the typical already-running default-browser path, prewarming completes well before
the user clicks a link.

Configuration recovery remains higher priority than prewarming: when launch must open recovery
settings, AppDelegate does not schedule chooser prewarming. Automatic profile-access presentation
continues through the same scheduled closure immediately after prewarming. Existing eligibility
checks still decide whether profile access is requested.

### Stage 2: Conditional Welcome Scene — abandoned

No Welcome-scene registration change was made. The runtime conditional `Scene` design is
incompatible with the installed SwiftUI `SceneBuilder` on macOS 14: general runtime `if` statements
require an unavailable `buildOptional` overload and fail compiling `PickViaApp.body` with `failed to
produce diagnostic for expression`. A `Group` wrapper fails identically. The user chose to retain
the Stage 1 prewarm only rather than add a macOS 15 `#available` split, a timer, or an AppKit
replacement window. Existing Welcome lifecycle behavior, including completed-onboarding dismissal,
remains unchanged.

## Event Flow

### Normal launch with completed onboarding

1. Production composition loads configuration, browser status, and onboarding state.
2. `PickViaApp` retains the existing Welcome scene registration; its existing lifecycle may still
   render no content and dismiss on a completed-onboarding launch.
3. After launch, AppDelegate schedules chooser prewarming on the next main-run-loop turn.
4. The controller creates and lays out an unordered panel, then clears temporary presentation
   state.
5. A later HTTP or HTTPS link reuses the prepared panel and replaces its root presentation with the
   real request before ordering it on the active desktop.

### Link arrives before prewarming

1. The ordinary URL-routing path creates and presents the chooser as it does today.
2. The scheduled prewarm observes that the panel already exists and returns without mutation.

### Incomplete onboarding

1. The Welcome scene remains registered and opens normally.
2. Chooser prewarming remains invisible and independent of Welcome.
3. Completing onboarding retains the existing Welcome dismissal behavior.

## Failure Handling and Safety

Prewarming is best-effort and nonthrowing. Empty application or target lists still produce a valid
representative empty-state chooser, so failed or partial browser discovery does not introduce a new
launch failure. If the prewarm cannot run before a link, the existing lazy path is the fallback.

No asynchronous task may retain a user URL. The scheduled closure captures AppDelegate weakly and
reads the model's application and target values only when it executes. AppDelegate owns only the
narrow prewarmer dependency. Existing chooser dismissal, profile-access serialization, and
active-Space window policies remain unchanged.

## Testing

### Automated tests

- `prepare` creates reusable panel content but leaves `hasActivePresentation` false.
- `prepare` does not order or key the panel, install the key monitor, capture the pointer, or emit a
  presentation-change callback.
- Calling `prepare` twice is idempotent.
- A real request after `prepare` uses the real URL, callbacks, density, URL-visibility preference,
  and target selection behavior.
- A real presentation before the queued prewarm remains active and is not replaced.
- AppDelegate schedules one prewarm after an ordinary successful launch.
- AppDelegate does not prewarm during configuration recovery.
- Existing automatic profile-access scheduling behavior remains covered.
- Existing Welcome lifecycle, URL delivery, chooser interaction, and active-Space suites continue
  to pass.

Implementation follows red-green-refactor: each production behavior is introduced only after its
focused test fails for the expected reason.

### Performance verification

Temporary local timestamps may be used during verification but are removed before commit. Measure
at least five first real presentations after a completed prewarm and compare the median against the
recorded 50-60 millisecond fresh render/layout baseline. Acceptance requires:

- a median render/layout duration of 25 milliseconds or less, or an equivalent median reduction of
  at least 25 milliseconds;
- no regression in five reused-panel presentations.

External click-to-visible timing is recorded as observational evidence, not a hard gate, because
the WindowServer probe showed large reporting variance after panel reuse.

### Product regression verification

Using the rebuilt production bundle:

1. Trigger HTTP and HTTPS links with PickVia already running; confirm the chooser appears with the
   correct URL and target list.
2. Repeat from a cold process; correctness must remain intact even if prewarming loses the race.
3. Repeat the established two-desktop scenario with Settings open on another desktop; confirm no
   delayed desktop switch.
4. Verify mouse selection, number shortcuts, arrow/Return, Escape, copy URL, and browser-settings
   navigation.

## Verification and Rollback

Run focused tests with warnings as errors for Stage 1, then run the full suite, Swift format
lint, and `git diff --check`. Build the production app, run the bundle smoke test, verify its code
signature, and relaunch the exact bundle path before manual regression and timing checks.

If Stage 1 misses the app-side performance threshold, revert it rather than keeping unmeasured
startup complexity. No migration or configuration rollback is required because Stage 1 does not
change persisted data.

## References and investigation history

- Apple: [`Scene.defaultLaunchBehavior(_:)`](https://developer.apple.com/documentation/swiftui/scene/defaultlaunchbehavior%28_%3A%29)
- Apple: [`SceneLaunchBehavior.suppressed`](https://developer.apple.com/documentation/swiftui/scenelaunchbehavior/suppressed)
- Apple: [Customizing window styles and state restoration behavior in macOS](https://developer.apple.com/documentation/SwiftUI/Customizing-window-styles-and-state-restoration-behavior-in-macOS)
