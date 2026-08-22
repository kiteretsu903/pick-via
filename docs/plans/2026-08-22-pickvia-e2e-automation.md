# PickVia Dedicated E2E Automation Implementation Plan

> **For implementation:** Use `subagent-driven-development`, `test-driven-development`,
> `systematic-debugging`, and `verification-before-completion`. Execute the checkbox steps
> in order and stop at every explicit privacy, binary-isolation, and real-browser gate.

**Goal:** Build a separately compiled PickVia E2E application that selects one exact browser target internally, leaves normal/release binaries free of automation code, and unblocks the real installed-browser routing matrix.

**Architecture:** E2E-only code is compiled behind `PICKVIA_E2E_AUTOMATION`. A validated immutable control selects one exact enabled/available target through the existing chooser callback, then production `RoutingCoordinator` and `BrowserLauncher` perform the route. A bounded FIFO emits only a closed sanitized status. The helper receives the route over stdin and opens it with the exact E2E app; the URL stays out of driver/E2E/helper arguments and environment, status, harness output, task-root files, and clipboard. Production delivery from `BrowserLauncher` to the selected browser may use browser arguments, AppleEvents, or `NSWorkspace`, and browser-owned persistence is outside this harness guarantee.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Package Manager compile conditions, POSIX FIFO APIs, zsh packaging scripts, Python 3 localhost receiver/driver, XCTest and Swift Testing.

---

## File map

- Create `Sources/PickVia/E2E/E2EControl.swift`: E2E environment parsing, validation,
  target decision, and closed status values, entirely compile-gated.
- Create `Sources/PickVia/E2E/E2EStatusWriter.swift`: bounded nonblocking FIFO status writer,
  entirely compile-gated.
- Create `Sources/PickVia/E2E/E2EChooserPresenter.swift`: chooser wrapper that renders the
  ordinary presentation and selects one exact target through the existing callback.
- Modify `Sources/PickVia/App/AppDelegate.swift`: choose isolated support storage and the
  E2E wrapper only under the compile condition.
- Create `Tests/PickViaTests/E2EControlTests.swift`: exact validation/decision RED-GREEN tests.
- Create `Tests/PickViaTests/E2EStatusWriterTests.swift`: real FIFO and privacy tests.
- Create `Tests/PickViaTests/E2EChooserPresenterTests.swift`: selection, rejection, and
  one-selection-per-request tests.
- Modify `Tests/PickViaTests/AppCompositionTests.swift`: compile-gated composition and
  isolated-support assertions.
- Create `scripts/build-e2e-app.sh`: separate scratch build and `build-e2e/PickVia E2E.app`
  packaging.
- Create `scripts/smoke-test-e2e.sh`: E2E bundle identity, marker, resources, and signature.
- Create `scripts/browser-e2e/test-e2e-build-isolation.sh`: prove normal binary absence and
  E2E binary presence.
- Create `scripts/browser-e2e/open_with_app.swift`: stdin-only exact-app URL delivery helper.
- Create `scripts/browser-e2e/pickvia_e2e_driver.py`: bounded one-route process/FIFO/receiver
  orchestration.
- Create `scripts/browser-e2e/test_pickvia_e2e_driver.py`: fake-process privacy and cleanup
  tests for the driver.
- Modify `.gitignore`: ignore `.build-e2e/` and `build-e2e/` generated artifacts.
- Append `docs/testing/browser-compatibility-2026-08-21.md`: pilot and matrix evidence only
  after real execution.

---

### Task 1: Define and validate immutable E2E controls

**Files:**

- Create: `Sources/PickVia/E2E/E2EControl.swift`
- Create: `Tests/PickViaTests/E2EControlTests.swift`

- [ ] **Step 1: Write the compile-gated failing decision tests**

Create the test file under `#if PICKVIA_E2E_AUTOMATION` and define fixtures that never use
a routed URL or human profile label. Cover exact success and each closed rejection:

```swift
#if PICKVIA_E2E_AUTOMATION
import PickViaCore
import XCTest

@testable import PickVia

final class E2EControlTests: XCTestCase {
  func testExactAvailableWebTargetIsSelected() throws {
    let control = E2EControl(
      targetID: "com.microsoft.edgemac||normal",
      expectedBundleIdentifier: "com.microsoft.edgemac",
      expectedMode: .normal,
      sessionNonce: "session_0123456789",
      applicationSupportDirectory: URL(fileURLWithPath: "/private/tmp/pickvia-e2e-control"),
      statusFIFO: URL(fileURLWithPath: "/private/tmp/pickvia-e2e-control/status.fifo")
    )

    let decision = E2ETargetDecision.evaluate(
      control: control,
      requestKind: .web,
      applications: [Fixtures.edge],
      targets: [Fixtures.edgeNormal]
    )

    XCTAssertEqual(decision, .select(Fixtures.edgeNormal.id))
  }

  func testEveryUnsafeShapeIsRejectedWithoutFallback() {
    let cases: [(RouteKind, [RoutedApplication], [RouteTarget], E2ESelectionOutcome)] = [
      (.mail, [Fixtures.edge], [Fixtures.edgeNormal], .nonWebRequest),
      (.web, [], [Fixtures.edgeNormal], .targetBrowserMismatch),
      (.web, [Fixtures.edge], [], .targetMissing),
      (.web, [Fixtures.edge], [Fixtures.edgeNormal, Fixtures.edgeNormal], .targetAmbiguous),
      (.web, [Fixtures.edge], [Fixtures.disabledEdge], .targetDisabled),
      (.web, [Fixtures.edge], [Fixtures.unavailableEdge], .targetUnavailable),
      (.web, [Fixtures.chrome], [Fixtures.edgeNormal], .targetBrowserMismatch),
      (.web, [Fixtures.edge], [Fixtures.edgePrivate], .targetModeMismatch),
    ]

    for (kind, applications, targets, outcome) in cases {
      XCTAssertEqual(
        E2ETargetDecision.evaluate(
          control: Fixtures.control,
          requestKind: kind,
          applications: applications,
          targets: targets
        ),
        .reject(outcome)
      )
    }
  }
}
#endif
```

- [ ] **Step 2: Run the tests and verify meaningful RED**

Run:

```zsh
swift test --disable-sandbox -Xswiftc -DPICKVIA_E2E_AUTOMATION \
  --filter E2EControlTests
```

Expected: compile failure because `E2EControl`, `E2ETargetDecision`, and
`E2ESelectionOutcome` do not exist.

- [ ] **Step 3: Implement the minimal closed model and environment loader**

Create the source file entirely inside `#if PICKVIA_E2E_AUTOMATION`. Use these exact
environment keys and no URL key:

```swift
#if PICKVIA_E2E_AUTOMATION
import Foundation
import PickViaCore

enum E2EEnvironmentKey {
  static let targetID = "PICKVIA_E2E_TARGET_ID"
  static let bundleIdentifier = "PICKVIA_E2E_BUNDLE_ID"
  static let mode = "PICKVIA_E2E_MODE"
  static let sessionNonce = "PICKVIA_E2E_SESSION_NONCE"
  static let supportDirectory = "PICKVIA_E2E_SUPPORT_DIR"
  static let statusFIFO = "PICKVIA_E2E_STATUS_FIFO"
}

struct E2EControl: Equatable {
  let targetID: RouteTarget.ID
  let expectedBundleIdentifier: String
  let expectedMode: BrowserMode
  let sessionNonce: String
  let applicationSupportDirectory: URL
  let statusFIFO: URL

  static func load(environment: [String: String]) -> E2EControl? {
    guard
      let targetID = nonempty(environment[E2EEnvironmentKey.targetID], limit: 512),
      let bundleID = nonempty(environment[E2EEnvironmentKey.bundleIdentifier], limit: 255),
      let rawMode = environment[E2EEnvironmentKey.mode],
      let mode = BrowserMode(rawValue: rawMode),
      let nonce = environment[E2EEnvironmentKey.sessionNonce],
      nonce.range(of: #"^[A-Za-z0-9_-]{16,64}$"#, options: .regularExpression) != nil,
      let supportPath = environment[E2EEnvironmentKey.supportDirectory],
      let fifoPath = environment[E2EEnvironmentKey.statusFIFO]
    else { return nil }

    let support = URL(fileURLWithPath: supportPath, isDirectory: true).standardizedFileURL
    let fifo = URL(fileURLWithPath: fifoPath).standardizedFileURL
    guard support.path.hasPrefix("/private/tmp/pickvia-e2e-"),
      fifo.path.hasPrefix(support.path + "/")
    else { return nil }
    return E2EControl(
      targetID: targetID,
      expectedBundleIdentifier: bundleID,
      expectedMode: mode,
      sessionNonce: nonce,
      applicationSupportDirectory: support,
      statusFIFO: fifo
    )
  }
}

enum E2ESelectionOutcome: String, Equatable {
  case selected
  case controlMissing = "control-missing"
  case controlMalformed = "control-malformed"
  case targetMissing = "target-missing"
  case targetAmbiguous = "target-ambiguous"
  case targetDisabled = "target-disabled"
  case targetUnavailable = "target-unavailable"
  case targetBrowserMismatch = "target-browser-mismatch"
  case targetModeMismatch = "target-mode-mismatch"
  case nonWebRequest = "non-web-request"
  case launchError = "launch-error"
}

enum E2ETargetDecision: Equatable {
  case select(RouteTarget.ID)
  case reject(E2ESelectionOutcome)

  static func evaluate(
    control: E2EControl,
    requestKind: RouteKind,
    applications: [RoutedApplication],
    targets: [RouteTarget]
  ) -> E2ETargetDecision {
    guard requestKind == .web else { return .reject(.nonWebRequest) }
    let matches = targets.filter { $0.id == control.targetID }
    guard !matches.isEmpty else { return .reject(.targetMissing) }
    guard matches.count == 1 else { return .reject(.targetAmbiguous) }
    let target = matches[0]
    guard target.isEnabled else { return .reject(.targetDisabled) }
    guard target.availability == .available else { return .reject(.targetUnavailable) }
    guard
      let application = applications.first(where: { $0.id == target.applicationID }),
      application.bundleIdentifier == control.expectedBundleIdentifier,
      application.isAvailable(for: .web)
    else { return .reject(.targetBrowserMismatch) }
    guard case .browser(let options) = target.capability,
      options.mode == control.expectedMode
    else { return .reject(.targetModeMismatch) }
    return .select(target.id)
  }
}
#endif
```

Implement `nonempty` as a file-private helper that trims whitespace, rejects control
characters, and enforces the supplied UTF-8 byte limit.

- [ ] **Step 4: Add loader boundary tests and reach GREEN**

Add table tests for missing keys, invalid mode, control bytes, over-limit values,
non-`/private/tmp/pickvia-e2e-` support paths, and FIFO paths outside the support root.
Run the focused command again. Expected: all `E2EControlTests` pass.

- [ ] **Step 5: Commit Task 1**

```zsh
git add Sources/PickVia/E2E/E2EControl.swift Tests/PickViaTests/E2EControlTests.swift
git commit -m "test: define fail-closed e2e browser controls"
```

---

### Task 2: Add bounded sanitized FIFO status reporting

**Files:**

- Create: `Sources/PickVia/E2E/E2EStatusWriter.swift`
- Create: `Tests/PickViaTests/E2EStatusWriterTests.swift`

- [ ] **Step 1: Write real-FIFO RED tests**

Under the compile condition, create a unique temporary root, call `mkfifo`, and test the
exact serialized shape:

```swift
func testWriterEmitsOnlySessionAndClosedOutcome() throws {
  let root = makeUniqueTemporaryRoot()
  let fifo = root.appending(path: "status.fifo")
  XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
  let reader = try NonblockingFIFOReader(url: fifo)
  let writer = E2EStatusWriter()

  XCTAssertTrue(writer.write(.selected, sessionNonce: "session_0123456789", to: fifo))
  let object = try XCTUnwrap(reader.readJSONObject(deadline: .now() + 1))

  XCTAssertEqual(Set(object.keys), ["session", "outcome"])
  XCTAssertEqual(object["session"] as? String, "session_0123456789")
  XCTAssertEqual(object["outcome"] as? String, "selected")
}

func testWriterRejectsRegularFileSymlinkAndMissingReader() throws {
  let root = makeUniqueTemporaryRoot()
  let regular = root.appending(path: "regular")
  XCTAssertTrue(FileManager.default.createFile(atPath: regular.path, contents: Data()))
  let symlink = root.appending(path: "symlink")
  try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regular)
  let fifo = root.appending(path: "unread.fifo")
  XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

  let writer = E2EStatusWriter()
  XCTAssertFalse(writer.write(.selected, sessionNonce: "session_0123456789", to: regular))
  XCTAssertFalse(writer.write(.selected, sessionNonce: "session_0123456789", to: symlink))
  XCTAssertFalse(writer.write(.selected, sessionNonce: "session_0123456789", to: fifo))
}

func testEveryOutcomeContainsNoURLOrArbitraryTargetText() throws {
  let outcomes: [E2ESelectionOutcome] = [
    .selected, .controlMissing, .controlMalformed, .targetMissing, .targetAmbiguous,
    .targetDisabled, .targetUnavailable, .targetBrowserMismatch, .targetModeMismatch,
    .nonWebRequest, .launchError,
  ]
  for outcome in outcomes {
    let line = try E2EStatusRecord(
      session: "session_0123456789",
      outcome: outcome
    ).encodedLine()
    let text = try XCTUnwrap(String(data: line, encoding: .utf8))
    XCTAssertFalse(text.contains("://"))
    XCTAssertFalse(text.contains("target-id"))
    XCTAssertEqual(Set(try JSONSerialization.jsonObject(
      with: Data(line.dropLast())
    ) as! [String: String].keys), ["session", "outcome"])
  }
}
```

- [ ] **Step 2: Run and verify RED**

Run the flagged `E2EStatusWriterTests`. Expected: compile failure because the writer and
reader test helper do not exist.

- [ ] **Step 3: Implement a nonblocking FIFO writer**

Use `lstat` to require an existing FIFO owned by the current user, reject symlinks and
regular files, then use `open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)` and one bounded
`write`. Encode exactly:

```swift
struct E2EStatusRecord: Codable, Equatable {
  let session: String
  let outcome: E2ESelectionOutcome
}

protocol E2EStatusWriting {
  func write(_ outcome: E2ESelectionOutcome, sessionNonce: String, to fifo: URL) -> Bool
}
```

The encoder uses sorted keys and appends one newline. It never accepts arbitrary message
text.

- [ ] **Step 4: Run focused tests to GREEN**

Expected: all FIFO tests pass without a hanging reader/writer and the temporary root is
removed.

- [ ] **Step 5: Commit Task 2**

```zsh
git add Sources/PickVia/E2E/E2EStatusWriter.swift Tests/PickViaTests/E2EStatusWriterTests.swift
git commit -m "feat: add bounded e2e status channel"
```

---

### Task 3: Wrap the real chooser with exact internal selection

**Files:**

- Create: `Sources/PickVia/E2E/E2EChooserPresenter.swift`
- Create: `Tests/PickViaTests/E2EChooserPresenterTests.swift`

- [ ] **Step 1: Write presenter RED tests with a real callback boundary**

Define a base `ChooserPresenting` spy and injected status writer. Required tests:

```swift
@MainActor
func testPresenterRendersThenSelectsExactTargetOnce() async {
  let base = E2EBaseChooserSpy()
  let status = E2EStatusWriterSpy(succeeds: true)
  let presenter = E2EChooserPresenter(
    base: base,
    control: Fixtures.control,
    statusWriter: status
  )
  var selected: [RouteTarget.ID] = []

  presenter.present(
    request: Fixtures.request,
    applications: [Fixtures.edge],
    targets: [Fixtures.edgeNormal],
    error: nil,
    onSelection: { selected.append($0) },
    onCancel: {}
  )
  await Task.yield()

  XCTAssertEqual(base.presentCallCount, 1)
  XCTAssertEqual(selected, [Fixtures.edgeNormal.id])
  XCTAssertEqual(status.outcomes, [.selected])
}

@MainActor
func testRepeatedPresentationOfSameRequestNeverSelectsTwice() async {
  let fixture = makePresenterFixture()
  fixture.present(request: Fixtures.request)
  fixture.present(request: Fixtures.request)
  await Task.yield()
  XCTAssertEqual(fixture.selectedTargetIDs, [Fixtures.edgeNormal.id])
}

@MainActor
func testNewRequestWithSameControlSelectsIndependently() async {
  let fixture = makePresenterFixture()
  fixture.present(request: Fixtures.request)
  fixture.present(request: RoutingRequest(id: UUID(), kind: .web, url: Fixtures.request.url))
  await Task.yield()
  XCTAssertEqual(
    fixture.selectedTargetIDs,
    [Fixtures.edgeNormal.id, Fixtures.edgeNormal.id]
  )
}

@MainActor
func testLaunchErrorPresentationNeverRetriesSelection() async {
  let fixture = makePresenterFixture()
  fixture.present(request: Fixtures.request)
  fixture.present(
    request: Fixtures.request,
    error: LaunchFailure(message: "sanitized")
  )
  await Task.yield()
  XCTAssertEqual(fixture.selectedTargetIDs, [Fixtures.edgeNormal.id])
  XCTAssertEqual(fixture.status.outcomes, [.selected, .launchError])
}

@MainActor
func testRejectedControlDismissesBaseAndNeverFallsBack() async {
  let fixture = makePresenterFixture(targets: [])
  fixture.present(request: Fixtures.request)
  await Task.yield()
  XCTAssertTrue(fixture.selectedTargetIDs.isEmpty)
  XCTAssertEqual(fixture.base.dismissCallCount, 1)
  XCTAssertEqual(fixture.status.outcomes, [.targetMissing])
}

@MainActor
func testStatusFailurePreventsSelection() async {
  let fixture = makePresenterFixture(statusSucceeds: false)
  fixture.present(request: Fixtures.request)
  await Task.yield()
  XCTAssertTrue(fixture.selectedTargetIDs.isEmpty)
  XCTAssertEqual(fixture.base.dismissCallCount, 1)
}
```

- [ ] **Step 2: Run and verify RED**

Expected: missing `E2EChooserPresenter` compile failure.

- [ ] **Step 3: Implement the minimal wrapper**

The wrapper calls `base.present` first. It records the last selected request ID. On a
successful decision, it must successfully write `.selected` before scheduling the exact
callback on the main actor. On rejection or status failure it dismisses the base and never
calls `onSelection` or `onCancel`:

```swift
@MainActor
final class E2EChooserPresenter: ChooserPresenting {
  private let base: any ChooserPresenting
  private let control: E2EControl?
  private let statusWriter: any E2EStatusWriting
  private var lastSelectedRequestID: UUID?

  func present(
    request: RoutingRequest,
    applications: [RoutedApplication],
    targets: [RouteTarget],
    error: LaunchFailure?,
    onSelection: @escaping (RouteTarget.ID) -> Void,
    onCancel: @escaping () -> Void
  ) {
    base.present(
      request: request,
      applications: applications,
      targets: targets,
      error: error,
      onSelection: { _ in },
      onCancel: {}
    )
    guard error == nil, lastSelectedRequestID != request.id else {
      if error != nil { reject(.launchError, requestID: request.id) }
      return
    }
    guard let control else { reject(.controlMissing, requestID: request.id); return }
    switch E2ETargetDecision.evaluate(
      control: control,
      requestKind: request.kind,
      applications: applications,
      targets: targets
    ) {
    case .select(let targetID):
      guard statusWriter.write(.selected, sessionNonce: control.sessionNonce, to: control.statusFIFO)
      else { base.dismiss(); return }
      lastSelectedRequestID = request.id
      Task { @MainActor in onSelection(targetID) }
    case .reject(let outcome):
      reject(outcome, requestID: request.id)
    }
  }

  func dismiss() { base.dismiss() }
}
```

- [ ] **Step 4: Run focused tests to GREEN**

Run all three flagged E2E test classes. Expected: pass with no WindowServer dependency for
the wrapper tests (the base is injected).

- [ ] **Step 5: Commit Task 3**

```zsh
git add Sources/PickVia/E2E/E2EChooserPresenter.swift \
  Tests/PickViaTests/E2EChooserPresenterTests.swift
git commit -m "feat: select exact targets in e2e builds"
```

---

### Task 4: Compose isolated E2E application state

**Files:**

- Modify: `Sources/PickVia/App/AppDelegate.swift`
- Modify: `Tests/PickViaTests/AppCompositionTests.swift`

- [ ] **Step 1: Add compile-gated RED composition tests**

Test a small resolver rather than process globals directly:

```swift
#if PICKVIA_E2E_AUTOMATION
func testE2EEnvironmentUsesOnlyValidatedIsolatedSupportDirectory() throws {
  let control = try XCTUnwrap(E2EControl.load(environment: Fixtures.validEnvironment))
  XCTAssertEqual(
    E2EApplicationEnvironment.applicationSupportDirectory(control: control),
    control.applicationSupportDirectory
  )
}

@MainActor
func testE2ECompositionWrapsOrdinaryChooser() throws {
  let composition = AppComposition.makeChooser(
    ordinary: CompositionChooserSpy(),
    e2eControl: Fixtures.control,
    statusWriter: E2EStatusWriterSpy(succeeds: true)
  )
  XCTAssertTrue(composition is E2EChooserPresenter)
}
#endif
```

- [ ] **Step 2: Run flagged tests and verify RED**

Expected: missing resolver/factory compile errors.

- [ ] **Step 3: Add the compile-time composition branch**

Keep all environment lookup inside the compile condition:

```swift
#if PICKVIA_E2E_AUTOMATION
guard let e2eControl = E2EControl.load(environment: ProcessInfo.processInfo.environment)
else {
  E2EControlFailure.terminateProcess()
}
let applicationSupportDirectory = e2eControl.applicationSupportDirectory
#else
let applicationSupportDirectory = FileManager.default.urls(
  for: .applicationSupportDirectory,
  in: .userDomainMask
)[0].appending(path: "PickVia", directoryHint: .isDirectory)
#endif
```

`E2EControlFailure.terminateProcess()` writes one fixed URL-free diagnostic to stderr and
terminates with `EX_CONFIG`; it never constructs a predictable fallback storage path.
Inject a terminating closure in its focused unit test so the invalid-control branch is
verified without ending the test process.

Move the existing `ChooserPanelController` construction unchanged into an
`ordinaryChooser` local, preserving its preference, settings, presentation-change,
pointer, ordering, and key closures. Wrap that local only inside the flag. A
missing control produces an E2E presenter that reports `control-missing`; it must not use
the user's ordinary PickVia support directory and must not fall back to the ordinary
interactive chooser.

- [ ] **Step 4: Run flagged and ordinary suites**

Run `AppCompositionTests` once with the flag and once without it. Expected: both pass; the
ordinary suite retains the existing production dependency graph.

- [ ] **Step 5: Commit Task 4**

```zsh
git add Sources/PickVia/App/AppDelegate.swift Tests/PickViaTests/AppCompositionTests.swift
git commit -m "feat: isolate e2e application composition"
```

---

### Task 5: Package and prove binary isolation

**Files:**

- Create: `scripts/build-e2e-app.sh`
- Create: `scripts/smoke-test-e2e.sh`
- Create: `scripts/browser-e2e/test-e2e-build-isolation.sh`
- Modify: `.gitignore`

- [ ] **Step 1: Write the failing isolation contract**

The contract builds both apps and checks exact identities and strings:

```zsh
#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
normal="$repo_root/build/PickVia.app"
e2e="$repo_root/build-e2e/PickVia E2E.app"
marker="PICKVIA_E2E_AUTOMATION_ENABLED"

zsh "$repo_root/scripts/build-app.sh" >/dev/null
zsh "$repo_root/scripts/build-e2e-app.sh" >/dev/null

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$normal/Contents/Info.plist")" = \
  "dev.bozhenpeng.PickVia"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$e2e/Contents/Info.plist")" = \
  "dev.bozhenpeng.PickVia.E2E"

! strings "$normal/Contents/MacOS/PickVia" | grep -Fq "$marker"
! strings "$normal/Contents/MacOS/PickVia" | grep -Fq "PICKVIA_E2E_TARGET_ID"
strings "$e2e/Contents/MacOS/PickVia" | grep -Fq "$marker"
strings "$e2e/Contents/MacOS/PickVia" | grep -Fq "PICKVIA_E2E_TARGET_ID"
```

- [ ] **Step 2: Run and verify RED**

Expected: `scripts/build-e2e-app.sh` is missing.

- [ ] **Step 3: Implement the E2E packaging script**

Use a separate scratch path and output directory:

```zsh
swift build -c release \
  --scratch-path "$repo_root/.build-e2e" \
  -Xswiftc -DPICKVIA_E2E_AUTOMATION \
  -Xswiftc -warnings-as-errors

app="$repo_root/build-e2e/PickVia E2E.app"
contents="$app/Contents"
resources="$contents/Resources"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$resources"
cp "$repo_root/.build-e2e/release/PickVia" "$contents/MacOS/PickVia"
cp "$repo_root/Support/Info.plist" "$contents/Info.plist"
cp "$repo_root/Support/Icons/PickVia.icns" "$resources/PickVia.icns"
cp "$repo_root/Support/Icons/PickViaMenuBarTemplate.png" \
  "$resources/PickViaMenuBarTemplate.png"
chmod +x "$contents/MacOS/PickVia"
/usr/libexec/PlistBuddy -c \
  "Set :CFBundleIdentifier dev.bozhenpeng.PickVia.E2E" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :PickViaE2EAutomation bool true" "$contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$app"
```

Reference `E2EAutomationMarker.value` from the E2E composition so the marker is retained in
the E2E executable. Do not change `scripts/build-app.sh`.

- [ ] **Step 4: Implement E2E smoke and isolation checks**

`smoke-test-e2e.sh` requires the E2E bundle ID, marker plist key, executable/resources,
macOS 14 minimum, URL registrations, and strict codesign. Add `.build-e2e/` and
`build-e2e/` to `.gitignore`.

- [ ] **Step 5: Run contracts to GREEN**

Run:

```zsh
zsh scripts/browser-e2e/test-e2e-build-isolation.sh
zsh scripts/smoke-test.sh build/PickVia.app
zsh scripts/smoke-test-e2e.sh "build-e2e/PickVia E2E.app"
```

Expected: all exit 0; normal and E2E binaries have the exact opposite marker expectations.

- [ ] **Step 6: Commit Task 5**

```zsh
git add .gitignore scripts/build-e2e-app.sh scripts/smoke-test-e2e.sh \
  scripts/browser-e2e/test-e2e-build-isolation.sh
git commit -m "build: add isolated PickVia e2e application"
```

---

### Task 6: Build the bounded stdin route driver

**Files:**

- Create: `scripts/browser-e2e/open_with_app.swift`
- Create: `scripts/browser-e2e/pickvia_e2e_driver.py`
- Create: `scripts/browser-e2e/test_pickvia_e2e_driver.py`

- [ ] **Step 1: Write driver RED tests**

Use fake app/helper processes and temporary FIFOs. Cover:

The driver accepts exactly one initial status record. Only an initial `selected` may be
followed by exactly one `launch-error`; duplicates, any other second record, malformed
records, and unknown outcomes are invalid-status failures. Tests cover the valid
two-record sequence plus duplicate and other invalid second records.

```python
def test_driver_keeps_url_out_of_harness_control_and_output_channels(self):
    with DriverFixture() as fixture:
        result = fixture.run()
        route_bytes = fixture.route.encode()
        self.assertNotIn(route_bytes, b"\0".join(fixture.observed_argv))
        self.assertNotIn(route_bytes, b"\0".join(fixture.observed_environment))
        self.assertNotIn(route_bytes, result.status_line)
        for regular_file in fixture.regular_files():
            self.assertNotIn(route_bytes, regular_file.read_bytes())

def test_driver_requires_selected_status_and_independent_receiver_receipt(self):
    with DriverFixture(status_outcome="selected", delivers_receipt=False) as fixture:
        self.assertEqual(fixture.run().exit_code, DRIVER_RECEIPT_TIMEOUT)
    with DriverFixture(status_outcome="target-missing", delivers_receipt=True) as fixture:
        self.assertEqual(fixture.run().exit_code, DRIVER_SELECTION_REJECTED)

def test_driver_rejects_wrong_session_and_unknown_status(self):
    with DriverFixture(status_session="wrong_session_1234") as fixture:
        self.assertEqual(fixture.run().exit_code, DRIVER_INVALID_STATUS)
    with DriverFixture(status_outcome="arbitrary-message") as fixture:
        self.assertEqual(fixture.run().exit_code, DRIVER_INVALID_STATUS)

def test_driver_times_out_and_terminates_exact_children(self):
    with DriverFixture(app_hangs=True, timeout=0.25) as fixture:
        result = fixture.run()
        self.assertEqual(result.exit_code, DRIVER_TIMEOUT)
        self.assertEqual(set(fixture.terminated_pids), set(fixture.launched_child_pids))

def test_driver_cleans_fifo_receiver_and_isolated_support_root(self):
    with DriverFixture() as fixture:
        root = fixture.support_root
        result = fixture.run()
        self.assertEqual(result.exit_code, 0)
    self.assertFalse(root.exists())

def test_driver_never_terminates_preexisting_processes(self):
    with DriverFixture(preexisting_pids={41, 42}) as fixture:
        fixture.run()
        self.assertTrue({41, 42}.isdisjoint(fixture.terminated_pids))
```

Implement `DriverFixture` in the test file with executable fake app/helper scripts, a real
temporary FIFO, an injected monotonic clock, and explicit child/preexisting PID sets. Its
`regular_files()` returns only files inside its unique task root; no broad filesystem scan
is permitted.

The tests scan captured argv/env/stdout/stderr and all regular files in the temporary root
for forbidden route components.

- [ ] **Step 2: Run and verify RED**

Run `python3 scripts/browser-e2e/test_pickvia_e2e_driver.py -v`. Expected: import failure
because `pickvia_e2e_driver.py` is missing.

- [ ] **Step 3: Add the exact-app stdin helper**

The Swift helper accepts exactly one `.app` path argument, reads URL bytes only from stdin,
rejects oversized/non-HTTP(S) input, and calls:

```swift
let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.addsToRecentItems = false
NSWorkspace.shared.open(
  [url],
  withApplicationAt: applicationURL,
  configuration: configuration
) { _, error in
  exit(error == nil ? EXIT_SUCCESS : EXIT_FAILURE)
}
```

It emits no URL or arbitrary error text.

- [ ] **Step 4: Implement the bounded Python orchestration**

The driver:

1. creates one unique `/private/tmp/pickvia-e2e-...` root and `0600` FIFO;
2. starts `localhost_probe.py` for one token;
3. constructs the route only in Python memory;
4. launches the exact E2E executable with the six non-URL control values;
5. compiles/starts the exact-app helper and writes the route to its stdin;
6. waits concurrently for one valid FIFO status and one receiver receipt with a monotonic
   deadline;
7. requires exact E2E and selected-browser process identities and reports only sanitized
   JSON (`session`, `outcome`, token receipt boolean, identity booleans, actual total
   elapsed seconds, route-proof timeout, browser-cleanup grace, and browser-quiescence
   bound); and
8. preserves preexisting browser generations, terminates only one unambiguous task-owned
   generation, drains owned output, then removes the FIFO/root.

Browser process inspection must return an authoritative snapshot or a sanitized
identity-inspection failure. Abort before route delivery when the baseline is unknown;
never attribute ownership after an observation failure; and treat unknown cleanup,
revalidation, or absence scans as cleanup failures. Only a confirmed disappeared-PID
race is benign. After closing every direct route producer, compare a final authoritative
exact-executable snapshot with both the immutable baseline and every accumulated new
generation. Any remaining non-baseline generation prevents success; terminate it only
when the accumulated attribution remains unambiguous.

All browser termination attempts share one five-second cleanup deadline. Poll the exact
target PID/start/executable identity during that grace, perform a final target check at the
deadline boundary, and never signal the same generation twice. Full authoritative
post-termination and final snapshots still decide replacement, multiple-generation, and
unknown-state failures.

After all route producers and the ordinary final sweep stop, require a two-second
quiescence window of repeated authoritative exact-browser snapshots against the immutable
baseline. A late generation always prevents success. Terminate one unambiguous late
generation at most once under the remaining shared cleanup deadline, verify absence, and
continue observing through the window boundary; repeated, replacement, multiple, and
unknown states remain ambiguous or fail closed.

This privacy contract applies to the driver, E2E app/helper controls, status, harness
output, task root, and clipboard. It does not claim that production `BrowserLauncher` or
the target browser avoids browser argv, AppleEvents, `NSWorkspace`, history, or other
browser-owned persistence.

Reject any count other than one route and cap every deadline at 30 seconds. Keep default
stdout/stderr free of the app route and helper errors.

- [ ] **Step 5: Run driver tests to GREEN**

Run the  Python suite with `PYTHONPYCACHEPREFIX` under a unique temporary directory. Scan
the repository for `__pycache__` afterward. Expected: all pass and no task process/root
remains.

- [ ] **Step 6: Commit Task 6**

```zsh
git add scripts/browser-e2e/open_with_app.swift \
  scripts/browser-e2e/pickvia_e2e_driver.py \
  scripts/browser-e2e/test_pickvia_e2e_driver.py
git commit -m "test: automate exact PickVia e2e selection"
```

---

### Task 7: Run the Edge Stable proof gate

**Files:**

- Append after PASS/FAIL is known: `docs/testing/browser-compatibility-2026-08-21.md`

- [ ] **Step 1: Preserve exact pre-state**

Record read-only exact PIDs/paths/start times for installed PickVia, E2E PickVia, Edge, and
the receiver. Do not print process arguments. Stop installed PickVia only if necessary and
restore it afterward.

- [ ] **Step 2: Run Edge normal cold state**

Build E2E, compute the canonical Edge normal target ID, start the driver, and require:

- FIFO outcome `selected`;
- fresh receiver receipt;
- exact `/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge` PID;
- Microsoft Edge stable bundle/version identity; and
- sanitized Computer Use evidence containing only edition/onboarding/window booleans.

No raw accessibility tree may be emitted.

- [ ] **Step 3: Run already-running and reopen states**

Repeat with fresh tokens while the exact Edge process is already running, then after
closing only the generated Edge window/process state supported by the matrix protocol.
Every state must independently receive its token.

- [ ] **Step 4: Apply the pilot gate**

If all three pass, append a sanitized PASS ledger and proceed. If any fails, append the
exact harness/product classification, clean up, and stop before the full matrix.

- [ ] **Step 5: Verify and commit pilot evidence**

Run driver/unit/full suites, formatting, diff check, process cleanup, and privacy scans.
Commit only the report if evidence changed:

```zsh
git add docs/testing/browser-compatibility-2026-08-21.md
git commit -m "test: prove automated PickVia Edge routing"
```

---

### Task 8: Run the complete installed-browser matrix

**Files:**

- Modify: `docs/testing/browser-compatibility-2026-08-21.md`

- [ ] **Step 1: Create only exact synthetic profiles**

For each advertised file-backed strategy, create `PickVia E2E` through the browser's
supported profile flow without sign-in, sync, import, extension installation, or unrelated
profile inspection. Record only the opaque selector needed by PickVia.

- [ ] **Step 2: Verify isolated E2E discovery**

Use the E2E support root to rescan the 22 installed descriptors. Chromium remains absent.
Require distinct application/target IDs and the exact capability matrix from the committed
descriptor table.

- [ ] **Step 3: Run every normal target**

For all 22 installed editions, run cold, already-running, and reopen routes with fresh
tokens. Preserve preexisting Chrome/Brave state unless an exact reversible close was
authorized; classify an unrun state separately from a product failure.

- [ ] **Step 4: Run all advertised profile/private targets**

Run the 13 installed Chromium-strategy editions and three Firefox editions against exact
synthetic profiles, plus all 16 advertised private modes and DuckDuckGo Fire. Require
fresh receipts, exact edition/process identity, and sanitized profile/private evidence.

Safari/STP/Opera/Arc/Orion enhanced cells remain `UNSUPPORTED`; Chromium is not installed.

- [ ] **Step 5: Record and reconcile one result per cell**

Record `PASS`, `FAIL`, `UNSUPPORTED`, or `NOT RUN` with explicit harness/product
classification, installed version, bundle ID, strategy, state results, receipt, evidence,
and cleanup. Never convert a harness failure into a product failure or borrow evidence
between editions.

- [ ] **Step 6: Clean exact task state**

Remove only confirmed task-owned profiles, E2E support roots, FIFOs, receivers, helpers,
and E2E app processes. Restore installed PickVia and preserved browser pre-state. Leave
ambiguous state untouched and report it.

- [ ] **Step 7: Run final gates and commit the matrix**

Run:

```zsh
swift test --disable-sandbox -Xswiftc -warnings-as-errors
swift test --disable-sandbox -Xswiftc -DPICKVIA_E2E_AUTOMATION -Xswiftc -warnings-as-errors
zsh scripts/browser-e2e/test-e2e-build-isolation.sh
python3 scripts/browser-e2e/test_localhost_probe.py -v
python3 scripts/browser-e2e/test_pickvia_e2e_driver.py -v
xcrun swift-format lint --recursive Sources Tests
git diff --check
git status --short
```

Expected: zero failures/warnings; report matrix complete; no task process/temp/profile state
left except any explicitly documented ambiguous item.

```zsh
git add docs/testing/browser-compatibility-2026-08-21.md
git commit -m "test: record real installed-browser matrix"
```

---

### Task 9: Cross-task review and handoff to capability reconciliation

**Files:**

- Review: all files changed since `cc76247`
- Conditional modify: `docs/plans/2026-08-21-browser-editions-and-families.md`

- [ ] **Step 1: Run a spec review**

Confirm the compiled isolation, privacy contract, fail-closed selection, Edge pilot, full
matrix, and cleanup satisfy
`docs/specs/2026-08-22-pickvia-e2e-automation-design.md`.

- [ ] **Step 2: Run a code-quality/security review**

Inspect environment parsing, FIFO validation, status blocking, request replay, normal
binary absence, process ownership, URL leakage, and cleanup. Fix Critical/Important issues
through fresh RED/GREEN cycles and re-review.

- [ ] **Step 3: Correct the stale packaged-app checklist identity**

Change only the stale Task 8 plan sentence from `com.pickvia.app` to the established
`dev.bozhenpeng.PickVia`; do not change product identity or the OSLog subsystem in this
task.

- [ ] **Step 4: Hand off truthful failures to Task 10**

Only real product/capability failures enter Task 10 removal work. Harness failures remain
documented as harness failures. The branch must be clean before reconciliation begins.
