# Chooser Neutral Initial State Implementation Plan

> **For implementers:** Execute this single task test-first, review the resulting diff, and keep all generated build output untracked.

**Goal:** Make every new chooser open without a selected target while preserving explicit keyboard, mouse, shortcut, and rerender behavior.

**Architecture:** `ChooserPresentation` remains the sole owner of selection state. Remove its implicit first-row fallback and teach arrow movement how to enter selection from nil; the existing view automatically stops drawing selected styling when `selectedIndex` is nil.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Swift Package Manager.

## Global Constraints

- A newly opened chooser has no selected target.
- Return does nothing until the user selects a target.
- Down from no selection selects the first target.
- Up from no selection selects the last target.
- Existing wraparound behavior remains after selection.
- Mouse clicks and number/letter shortcuts remain unchanged.
- Same-request rerenders preserve explicit selection and preserve nil when no selection exists.
- Add no new dependencies or persisted settings.
- Keep `.build/` and `build/` untracked.

---

### Task 1: Neutral initial selection and explicit keyboard entry

**Files:**

- Modify: `Sources/PickVia/Chooser/ChooserModels.swift:158-187`
- Modify: `Tests/PickViaTests/ChooserModelsTests.swift:121-177`

**Interfaces:**

- Consumes: existing `ChooserPresentation.make`, `moveSelection(_:)`, `handle(_:)`, `ChooserSelectionDirection`, and `ChooserAction`.
- Produces: `ChooserPresentation.make(...preservingSelection:)` with a nil default selection and direction-specific entry into selection from nil.

- [ ] **Step 1: Replace the initial-selection test with failing neutral-state tests**

Replace `testArrowMovementWrapsAtBothEnds` and adjust the adjacent Return test:

```swift
func testPresentationStartsNeutralAndReturnDoesNothing() {
  let presentation = makePresentation(
    applications: [Fixtures.chrome],
    targets: [Fixtures.work, Fixtures.personal]
  )

  XCTAssertNil(presentation.selectedIndex)
  XCTAssertEqual(presentation.handle(.returnKey), .none)
}

func testDownFromNeutralSelectsFirstThenWraps() {
  var presentation = makePresentation(
    applications: [Fixtures.chrome],
    targets: [Fixtures.work, Fixtures.personal]
  )

  presentation.moveSelection(.down)
  XCTAssertEqual(presentation.selectedIndex, 0)
  presentation.moveSelection(.up)
  XCTAssertEqual(presentation.selectedIndex, 1)
  presentation.moveSelection(.down)
  XCTAssertEqual(presentation.selectedIndex, 0)
}

func testUpFromNeutralSelectsLast() {
  var presentation = makePresentation(
    applications: [Fixtures.chrome],
    targets: [Fixtures.work, Fixtures.personal]
  )

  presentation.moveSelection(.up)

  XCTAssertEqual(presentation.selectedIndex, 1)
}

func testReturnSelectsExplicitCurrentRowAndEscapeCancels() {
  var presentation = makePresentation(
    applications: [Fixtures.chrome],
    targets: [Fixtures.work, Fixtures.personal]
  )
  presentation.moveSelection(.down)
  presentation.moveSelection(.down)

  XCTAssertEqual(presentation.handle(.returnKey), .select("personal"))
  XCTAssertEqual(presentation.handle(.escape), .cancel)
}
```

Update `testErrorStatePreservesCurrentSelection` to call `moveSelection(.down)` twice before asserting index 1.

- [ ] **Step 2: Add failing rerender-state tests**

Add tests proving `preservingSelection` distinguishes explicit and neutral state:

```swift
func testMakePreservesExplicitSelectionAcrossRerender() {
  let presentation = ChooserPresentation.make(
    request: Fixtures.request,
    applications: [Fixtures.chrome],
    targets: [Fixtures.work, Fixtures.personal],
    error: LaunchFailure(message: "Safe launch error"),
    preservingSelection: Fixtures.personal.id
  )

  XCTAssertEqual(presentation.selectedIndex, 1)
}

func testMakePreservesNeutralSelectionAcrossRerender() {
  let presentation = ChooserPresentation.make(
    request: Fixtures.request,
    applications: [Fixtures.chrome],
    targets: [Fixtures.work, Fixtures.personal],
    error: LaunchFailure(message: "Safe launch error"),
    preservingSelection: nil
  )

  XCTAssertNil(presentation.selectedIndex)
}
```

Use the fixture target ID constants that already exist in `Fixtures`; if those targets are stored as values rather than exposing nested `id` statically, pass the literal IDs `"work"` and `"personal"` used by the surrounding tests.

- [ ] **Step 3: Run focused tests and confirm RED**

Run:

```bash
swift test --filter ChooserModelsTests
```

Expected failures:

- initial `selectedIndex` is `0` instead of nil;
- Return selects `"work"` instead of `.none`;
- Down from neutral selects index `1` instead of index `0`;
- neutral rerender selects index `0`.

- [ ] **Step 4: Remove implicit initial selection**

In `ChooserPresentation.make`, replace the fallback expression:

```swift
let selectedIndex = targetID.flatMap { selectedID in
  rows.firstIndex { $0.targetID == selectedID }
}
```

An absent or stale preserved target now produces nil.

- [ ] **Step 5: Add direction-specific entry from neutral state**

Update `moveSelection(_:)`:

```swift
public mutating func moveSelection(_ direction: ChooserSelectionDirection) {
  guard !rows.isEmpty else {
    selectedIndex = nil
    return
  }

  guard let current = selectedIndex else {
    selectedIndex =
      switch direction {
      case .up: rows.count - 1
      case .down: 0
      }
    return
  }

  switch direction {
  case .up:
    selectedIndex = (current - 1 + rows.count) % rows.count
  case .down:
    selectedIndex = (current + 1) % rows.count
  }
}
```

Do not change `handle(.returnKey)`: its existing nil guard already produces `.none`. Do not change shortcut handling or the SwiftUI row component.

- [ ] **Step 6: Run focused tests and confirm GREEN**

Run:

```bash
swift test --filter ChooserModelsTests
```

Expected: all `ChooserModelsTests` pass, including direct number/letter shortcuts and the target-after-Z arrow test.

- [ ] **Step 7: Run complete verification**

Run:

```bash
swift test -Xswiftc -warnings-as-errors
./scripts/build-app.sh
git diff --check
git status --short
```

Expected:

- all XCTest and Swift Testing cases pass with zero warnings promoted to errors;
- `build/PickVia.app` is rebuilt and signed;
- no whitespace errors;
- only the two intended source/test files are modified before commit;
- build directories remain ignored.

- [ ] **Step 8: Manually verify the rebuilt chooser**

Open the rebuilt app, trigger `Test Browser Chooser…`, and confirm:

- no row has a blue selected fill or border initially;
- Return has no effect;
- Down highlights Safari;
- Escape closes the chooser;
- a number or letter shortcut still launches its assigned target.

- [ ] **Step 9: Commit**

```bash
git add Sources/PickVia/Chooser/ChooserModels.swift Tests/PickViaTests/ChooserModelsTests.swift
git commit -m "fix: open chooser without initial selection"
```

## Final Review

- Compare the diff against `docs/specs/2026-07-23-chooser-neutral-initial-state-design.md`.
- Confirm no view-only flag hides a still-active logical selection.
- Confirm explicit selection preservation remains target-ID based.
- Confirm no persisted preference or configuration schema changed.
