# PickVia Chooser UI Polish Implementation Plan

> **For implementers:** Execute this plan task-by-task with a fresh review after each commit. Keep the checkbox state in this file current while working.

**Goal:** Deliver a compact, one-line browser chooser with native selection styling, three persisted density presets, and the approved enabled-state defaults for detected normal/private targets.

**Architecture:** Keep target-default behavior in `PickViaCore`, and keep chooser density and presentation in the macOS app target. A small density value type owns all sizing metrics; `AppModel` persists the selected case; `ChooserPanelController` snapshots it for each new request; and focused SwiftUI views consume the metrics without changing routing or keyboard behavior.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, XCTest, Swift Testing, Swift Package Manager.

## Global Constraints

- Use the approved grouped, one-line chooser direction.
- Density names are exactly `Compact`, `Balanced`, and `Spacious`.
- Compact is the missing/invalid-preference fallback and the default.
- Detected defaults are: browser normal on, browser private on, profile normal on, profile private off.
- Migrate existing detected targets once; never rewrite manual target enabled states.
- After schema migration, preserve later user toggles during rescans.
- Keep URL visibility, grouping, shortcuts, arrow navigation, pointer anchoring, scrolling, errors, and footer actions working.
- Add no third-party dependencies.
- Keep generated `.build/` and `build/` output untracked.

## File Map

- Create `Sources/PickVia/Chooser/ChooserDensity.swift`: density cases, persistence decoding, labels, and all chooser layout metrics.
- Create `Sources/PickVia/Chooser/ChooserTargetRow.swift`: one-line target button, hover state, selected tint/border, optional browser icon, and shortcut badge.
- Modify `Sources/PickViaCore/Models/PickViaConfig.swift`: schema version 2 and one-time detected-target normalization.
- Modify `Sources/PickViaCore/Discovery/BrowserCatalog.swift`: approved enabled states for newly detected targets.
- Modify `Sources/PickVia/App/AppModel.swift`: persisted density property and preference key.
- Modify `Sources/PickVia/App/AppDelegate.swift`: inject a live density provider into the chooser.
- Modify `Sources/PickVia/Views/GeneralSettingsView.swift`: segmented density picker.
- Modify `Sources/PickVia/Chooser/ChooserPanelController.swift`: snapshot density per request and size the panel with its metrics.
- Modify `Sources/PickVia/Chooser/ChooserPanelLayout.swift`: remove the single fixed content-width constant.
- Modify `Sources/PickVia/Chooser/ChooserView.swift`: consume density metrics, use one-line rows, and delegate row visuals.
- Modify core and app test files listed below for migration, discovery, preferences, layout, composition, and view structure.

---

### Task 1: Detected-target defaults and one-time configuration migration

**Files:**

- Modify: `Sources/PickViaCore/Models/PickViaConfig.swift:1-95`
- Modify: `Sources/PickViaCore/Discovery/BrowserCatalog.swift:532-585`
- Test: `Tests/PickViaCoreTests/ConfigStoreTests.swift`
- Test: `Tests/PickViaCoreTests/BrowserCatalogTests.swift:334-390`

**Interfaces:**

- Consumes: existing `BrowserTarget`, `BrowserTargetOrigin`, `BrowserMode`, and `BrowserFamily` values.
- Produces: `PickViaConfig.currentSchemaVersion == 2` and a single candidate-default rule: `profile == nil || mode == .normal`.

- [ ] **Step 1: Add failing discovery-default tests**

Update the two existing expectations for the browser-default private target and add an explicit four-state matrix test:

```swift
@Test func detectedTargetDefaultsEnableOnlyBrowserPrivateAndAllNormalTargets() {
  let discovered = chrome(profiles: [
    DiscoveredProfile(
      identifier: "Default",
      displayName: "Personal",
      directoryURL: nil,
      isDefault: true
    ),
    DiscoveredProfile(identifier: "Profile 1", displayName: "Work", directoryURL: nil),
  ])

  let result = BrowserCatalog.reconcile(discovered: [discovered], with: .initial)
  let values = result.targets.map { target in
    (target.profileIdentity == nil, target.mode, target.isEnabled)
  }

  #expect(values.count == 4)
  #expect(values[0].0 && values[0].1 == .normal && values[0].2)
  #expect(values[1].0 && values[1].1 == .private && values[1].2)
  #expect(!values[2].0 && values[2].1 == .normal && values[2].2)
  #expect(!values[3].0 && values[3].1 == .private && !values[3].2)
}
```

Also change `emptyProfileMetadataCreatesUnprofiledNormalAndPrivateFallbacks` to expect `[true, true]`, and change `chromiumAlwaysCreatesBrowserDefaultAndAbsorbsCanonicalDirectory` to expect the second target to be enabled.

- [ ] **Step 2: Run the focused catalog tests and confirm failure**

Run:

```bash
swift test --filter BrowserCatalogTests
```

Expected: failures show that browser-default private targets are still disabled.

- [ ] **Step 3: Implement the new-candidate matrix**

In `BrowserCatalog.candidate`, replace the mode-only default with:

```swift
isEnabled: profile == nil || mode == .normal,
```

This enables both unprofiled browser targets and only the normal target for a named profile.

- [ ] **Step 4: Re-run the focused catalog tests**

Run:

```bash
swift test --filter BrowserCatalogTests
```

Expected: all `BrowserCatalogTests` pass.

- [ ] **Step 5: Add failing schema-migration tests**

In `ConfigStoreTests`, construct four detected Chromium targets at schema 1 with deliberately inverted enabled states plus one manual target. Assert that loading produces schema 2 and the approved matrix while preserving the manual target:

```swift
func testSchemaOneNormalizesDetectedTargetEnabledStatesOnce() throws {
  let browser = validChrome
  let detected = [
    makeTarget(id: "default-normal", profile: nil, mode: .normal, enabled: false),
    makeTarget(id: "default-private", profile: nil, mode: .private, enabled: false),
    makeTarget(id: "work-normal", profile: "Profile 1", mode: .normal, enabled: false),
    makeTarget(id: "work-private", profile: "Profile 1", mode: .private, enabled: true),
  ]
  let manual = makeTarget(
    id: "manual-private",
    profile: "Profile 1",
    mode: .private,
    enabled: true,
    origin: .manual
  )

  let migrated = try PickViaConfig(
    schemaVersion: 1,
    browsers: [browser],
    targets: detected + [manual]
  ).validatedAndMigrated()

  XCTAssertEqual(migrated.schemaVersion, 2)
  XCTAssertEqual(migrated.targets.map(\.isEnabled), [true, true, true, false, true])
}
```

Add a second test proving schema 2 preserves detected user choices:

```swift
func testCurrentSchemaPreservesDetectedEnabledStates() throws {
  let target = makeTarget(
    id: "default-private",
    profile: nil,
    mode: .private,
    enabled: false
  )
  let validated = try PickViaConfig(
    schemaVersion: 2,
    browsers: [validChrome],
    targets: [target]
  ).validatedAndMigrated()

  XCTAssertFalse(validated.targets[0].isEnabled)
}
```

Implement `makeTarget` as a test helper using the repository's existing valid bundle identifier and canonical target IDs; when `profile` is non-nil, populate `profileIdentifier`, `profileDisplayName`, and `profileIdentity` consistently.

- [ ] **Step 6: Run the migration tests and confirm failure**

Run:

```bash
swift test --filter ConfigStoreTests
```

Expected: the new tests fail because the current schema is 1 and no enabled-state normalization occurs.

- [ ] **Step 7: Implement schema version 2 migration**

Set `currentSchemaVersion` to 2. In `validatedAndMigrated()`, preserve the original schema for the migration decision, validate the input as today, and map targets only when `schemaVersion < 2`:

```swift
let migratedTargets = targets.map { target in
  guard schemaVersion < 2,
    target.origin == .detected,
    let browser = browsers.first(where: { $0.id == target.browserID }),
    browser.family == .chromium || browser.family == .firefox
  else { return target }

  let hasExplicitProfile =
    target.profileIdentity != nil
    || target.profileIdentifier != nil
    || target.profileDisplayName != nil
    || target.profileLaunchPath != nil
  let shouldEnable = !hasExplicitProfile || target.mode == .normal

  return BrowserTarget(
    id: target.id,
    browserID: target.browserID,
    label: target.label,
    profileIdentifier: target.profileIdentifier,
    profileDisplayName: target.profileDisplayName,
    profileIdentity: target.profileIdentity,
    profileLaunchPath: target.profileLaunchPath,
    mode: target.mode,
    isEnabled: shouldEnable,
    sortOrder: target.sortOrder,
    origin: target.origin,
    availability: target.availability,
    pendingDefaultMigration: target.pendingDefaultMigration,
    validationError: target.validationError
  )
}
```

Return `migratedTargets` with schema 2. Update existing tests that hard-code schema 1 only where they assert the post-validation schema; fixtures representing already-current documents should use `PickViaConfig.currentSchemaVersion` to keep their intended semantics.

- [ ] **Step 8: Verify core behavior**

Run:

```bash
swift test --filter ConfigStoreTests
swift test --filter BrowserCatalogTests
```

Expected: both suites pass, including the new matrix, one-time migration, manual preservation, and current-schema preservation tests.

- [ ] **Step 9: Commit Task 1**

```bash
git add Sources/PickViaCore/Models/PickViaConfig.swift Sources/PickViaCore/Discovery/BrowserCatalog.swift Tests/PickViaCoreTests/ConfigStoreTests.swift Tests/PickViaCoreTests/BrowserCatalogTests.swift
git commit -m "feat: refine detected browser target defaults"
```

---

### Task 2: Density model, persistence, and settings control

**Files:**

- Create: `Sources/PickVia/Chooser/ChooserDensity.swift`
- Modify: `Sources/PickVia/App/AppModel.swift:28-40,153-155,202-205,904-907`
- Modify: `Sources/PickVia/Views/GeneralSettingsView.swift:20-31`
- Test: `Tests/PickViaTests/AppModelTests.swift:9-37,1699-1707`
- Test: `Tests/PickViaTests/BrowserSettingsViewTests.swift`

**Interfaces:**

- Produces: `ChooserDensity`, `ChooserMetrics`, `ChooserDensity.fromPersistedValue(_:)`, `AppModel.chooserDensity`, and `PreferenceKey.chooserDensity`.
- Consumed by: Tasks 3 and 4.

- [ ] **Step 1: Write failing density-model and persistence tests**

Add tests in `AppModelTests`:

```swift
func testDensityUsesCompactForMissingAndInvalidPreference() throws {
  let missingModel = makeModel(preferences: PreferencesStub())
  try missingModel.load()
  XCTAssertEqual(missingModel.chooserDensity, .compact)

  let invalidModel = makeModel(preferences: PreferencesStub(integers: ["chooserDensity": 99]))
  try invalidModel.load()
  XCTAssertEqual(invalidModel.chooserDensity, .compact)
}

func testDensityLoadsAndPersistsEveryPreset() throws {
  let preferences = PreferencesStub(integers: ["chooserDensity": ChooserDensity.balanced.rawValue])
  let model = makeModel(preferences: preferences)
  try model.load()
  XCTAssertEqual(model.chooserDensity, .balanced)

  model.chooserDensity = .spacious
  XCTAssertEqual(preferences.setIntegers["chooserDensity"], ChooserDensity.spacious.rawValue)
}
```

Add a focused unit test for exact names and ordered cases:

```swift
func testDensityDisplayOrderAndNames() {
  XCTAssertEqual(ChooserDensity.allCases, [.compact, .balanced, .spacious])
  XCTAssertEqual(ChooserDensity.allCases.map(\.title), ["Compact", "Balanced", "Spacious"])
}
```

- [ ] **Step 2: Run the app-model tests and confirm failure**

Run:

```bash
swift test --filter AppModelTests
```

Expected: compilation fails because `ChooserDensity` and `chooserDensity` do not exist.

- [ ] **Step 3: Create the density and metrics types**

Create `ChooserDensity.swift`:

```swift
import Foundation

public enum ChooserDensity: Int, CaseIterable, Identifiable, Sendable {
  case compact = 0
  case balanced = 1
  case spacious = 2

  public var id: Int { rawValue }

  public var title: String {
    switch self {
    case .compact: "Compact"
    case .balanced: "Balanced"
    case .spacious: "Spacious"
    }
  }

  public static func fromPersistedValue(_ value: Int?) -> ChooserDensity {
    value.flatMap(ChooserDensity.init(rawValue:)) ?? .compact
  }

  var metrics: ChooserMetrics {
    switch self {
    case .compact:
      ChooserMetrics(
        contentWidth: 340, outerPadding: 12, mainSpacing: 8,
        groupSpacing: 3, rowHorizontalPadding: 8, rowVerticalPadding: 3,
        headerHorizontalPadding: 8, headerVerticalPadding: 1
      )
    case .balanced:
      ChooserMetrics(
        contentWidth: 380, outerPadding: 14, mainSpacing: 10,
        groupSpacing: 6, rowHorizontalPadding: 10, rowVerticalPadding: 5,
        headerHorizontalPadding: 10, headerVerticalPadding: 2
      )
    case .spacious:
      ChooserMetrics(
        contentWidth: 420, outerPadding: 18, mainSpacing: 14,
        groupSpacing: 9, rowHorizontalPadding: 12, rowVerticalPadding: 8,
        headerHorizontalPadding: 12, headerVerticalPadding: 4
      )
    }
  }
}

struct ChooserMetrics: Equatable, Sendable {
  let contentWidth: CGFloat
  let outerPadding: CGFloat
  let mainSpacing: CGFloat
  let groupSpacing: CGFloat
  let rowHorizontalPadding: CGFloat
  let rowVerticalPadding: CGFloat
  let headerHorizontalPadding: CGFloat
  let headerVerticalPadding: CGFloat
}
```

- [ ] **Step 4: Add the persisted app-model property**

In `AppModel`, add:

```swift
public var chooserDensity: ChooserDensity {
  didSet {
    guard isLoaded else { return }
    preferences.set(chooserDensity.rawValue, forKey: PreferenceKey.chooserDensity)
  }
}
```

Initialize it to `.compact`, load it with:

```swift
chooserDensity = .fromPersistedValue(
  preferences.integer(forKey: PreferenceKey.chooserDensity)
)
```

and add:

```swift
static let chooserDensity = "chooserDensity"
```

to `PreferenceKey`.

- [ ] **Step 5: Add the segmented General Settings picker**

Place this directly below the URL visibility toggle:

```swift
Picker("Chooser size", selection: $model.chooserDensity) {
  ForEach(ChooserDensity.allCases) { density in
    Text(density.title).tag(density)
  }
}
.pickerStyle(.segmented)
```

Add a source-structure test in `BrowserSettingsViewTests` that asserts the General Settings source contains `Picker("Chooser size"`, `ChooserDensity.allCases`, and `.pickerStyle(.segmented)`.

- [ ] **Step 6: Verify Task 2**

Run:

```bash
swift test --filter AppModelTests
swift test --filter BrowserSettingsViewTests
```

Expected: both suites pass; missing and invalid values resolve to Compact, all values persist, and the segmented control is present.

- [ ] **Step 7: Commit Task 2**

```bash
git add Sources/PickVia/Chooser/ChooserDensity.swift Sources/PickVia/App/AppModel.swift Sources/PickVia/Views/GeneralSettingsView.swift Tests/PickViaTests/AppModelTests.swift Tests/PickViaTests/BrowserSettingsViewTests.swift
git commit -m "feat: add chooser density preference"
```

---

### Task 3: Density-aware panel sizing and composition

**Files:**

- Modify: `Sources/PickVia/Chooser/ChooserPanelController.swift:16-72,90-175,219-275`
- Modify: `Sources/PickVia/Chooser/ChooserPanelLayout.swift:8-12`
- Modify: `Sources/PickVia/App/AppDelegate.swift:162-176`
- Modify: `Tests/PickViaTests/ChooserModelsTests.swift:205-367,665-692`
- Modify: `Tests/PickViaTests/ChooserPanelLayoutTests.swift:5-17`
- Modify: `Tests/PickViaTests/AppCompositionTests.swift:165-189`

**Interfaces:**

- Consumes: `ChooserDensity.metrics` from Task 2.
- Produces: `ChooserPanelController.init(densityProvider:...)`, `densityForCurrentPresentation`, and density-correct panel content width.
- Consumed by: Task 4's `ChooserView` initializer.

- [ ] **Step 1: Add failing controller snapshot and sizing tests**

Add a mutable test preference and verify a new request snapshots the new value while an error rerender keeps the old one:

```swift
func testDensityIsResolvedForEachNewRequestAndRetainedForRerender() {
  var density = ChooserDensity.compact
  let controller = ChooserPanelController(densityProvider: { density })

  controller.present(
    request: Fixtures.request,
    applications: [Fixtures.chrome],
    targets: [Fixtures.work],
    error: nil,
    onSelection: { _ in },
    onCancel: {}
  )
  XCTAssertEqual(controller.densityForCurrentPresentation, .compact)
  XCTAssertEqual(controller.panelContentSizeForTesting.width, 340)

  density = .spacious
  controller.present(
    request: Fixtures.request,
    applications: [Fixtures.chrome],
    targets: [Fixtures.work],
    error: LaunchFailure(message: "Safe launch error"),
    onSelection: { _ in },
    onCancel: {}
  )
  XCTAssertEqual(controller.densityForCurrentPresentation, .compact)

  controller.dismiss()
  controller.present(
    request: RoutingRequest(url: URL(string: "https://example.com/new")!),
    applications: [Fixtures.chrome],
    targets: [Fixtures.work],
    error: nil,
    onSelection: { _ in },
    onCancel: {}
  )
  XCTAssertEqual(controller.densityForCurrentPresentation, .spacious)
  XCTAssertEqual(controller.panelContentSizeForTesting.width, 420)
  controller.dismiss()
}
```

Update the existing fixed-width assertions to use `.compact.metrics.contentWidth`.

- [ ] **Step 2: Run focused controller/layout tests and confirm failure**

Run:

```bash
swift test --filter ChooserPanelControllerTests
swift test --filter ChooserPanelLayoutTests
```

Expected: compilation fails because the density provider and snapshot do not exist.

- [ ] **Step 3: Inject and snapshot density in the controller**

Add:

```swift
private let densityProvider: @MainActor () -> ChooserDensity
private(set) var densityForCurrentPresentation: ChooserDensity = .compact
```

Add `densityProvider` with default `{ .compact }` to both initializers. In `present`, resolve it only for a new request:

```swift
if isNewRequest {
  densityForCurrentPresentation = densityProvider()
}
```

Pass `densityForCurrentPresentation` into `ChooserView`. Replace every use of `ChooserPanelLayout.contentWidth` in controller construction and fitting with:

```swift
let contentWidth = densityForCurrentPresentation.metrics.contentWidth
```

Remove `contentWidth` from `ChooserPanelLayout`; keep pointer gap, screen margin, maximum-height, and origin behavior unchanged.

- [ ] **Step 4: Wire the live preference into production composition**

In `AppDelegate.production`, add this chooser argument next to `showsURLProvider`:

```swift
densityProvider: {
  ChooserDensity.fromPersistedValue(
    preferences.integer(forKey: PreferenceKey.chooserDensity)
  )
},
```

Extend `AppCompositionTests.testAppModelURLPreferenceIsResolvedByChooserForEachPreview` or add a sibling test that changes the stored integer between previews and asserts the controller snapshots Compact then Spacious.

- [ ] **Step 5: Verify Task 3**

Run:

```bash
swift test --filter ChooserPanelControllerTests
swift test --filter ChooserPanelLayoutTests
swift test --filter AppCompositionTests
```

Expected: all suites pass; widths are 340, 380, and 420 where explicitly exercised, rerenders do not jump, and new requests adopt the latest preference.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/PickVia/Chooser/ChooserPanelController.swift Sources/PickVia/Chooser/ChooserPanelLayout.swift Sources/PickVia/App/AppDelegate.swift Tests/PickViaTests/ChooserModelsTests.swift Tests/PickViaTests/ChooserPanelLayoutTests.swift Tests/PickViaTests/AppCompositionTests.swift
git commit -m "feat: size chooser from density preference"
```

---

### Task 4: One-line rows and native selection polish

**Files:**

- Create: `Sources/PickVia/Chooser/ChooserTargetRow.swift`
- Modify: `Sources/PickVia/Chooser/ChooserView.swift:5-180`
- Modify: `Tests/PickViaTests/BrowserSettingsViewTests.swift:25-56`
- Modify: `Tests/PickViaTests/ChooserModelsTests.swift:336-367`

**Interfaces:**

- Consumes: `ChooserDensity` and `ChooserMetrics` from Task 2; density snapshot passed by Task 3; existing `ChooserShortcut` labels and target selection callbacks.
- Produces: `ChooserTargetRow` as the focused visual component and a `ChooserView` initializer with `density: ChooserDensity`.

- [ ] **Step 1: Replace the old two-line source test with failing one-line/style tests**

In `BrowserSettingsViewTests`, replace `testChooserTargetLabelAndDetailUseOneLineTailTruncation` with:

```swift
func testChooserRowsAreSingleLineAndDoNotRenderDetailText() throws {
  let source = try projectSource("Sources/PickVia/Chooser/ChooserView.swift")
  XCTAssertFalse(source.contains("detail(for:"))
  XCTAssertTrue(source.contains("ChooserTargetRow("))

  let rowSource = try projectSource("Sources/PickVia/Chooser/ChooserTargetRow.swift")
  XCTAssertTrue(rowSource.contains("Text(label)"))
  XCTAssertTrue(rowSource.contains(".lineLimit(1)"))
  XCTAssertTrue(rowSource.contains(".truncationMode(.tail)"))
  XCTAssertFalse(rowSource.contains("VStack"))
}

func testChooserSelectionUsesTintAndInsetBorderWithoutShadow() throws {
  let source = try projectSource("Sources/PickVia/Chooser/ChooserTargetRow.swift")
  XCTAssertTrue(source.contains("Color.accentColor.opacity"))
  XCTAssertTrue(source.contains(".strokeBorder"))
  XCTAssertFalse(source.contains(".shadow"))
}
```

Update the existing adaptive-scrolling test to assert `.frame(width: density.metrics.contentWidth)` instead of the removed fixed layout width.

- [ ] **Step 2: Run the focused view tests and confirm failure**

Run:

```bash
swift test --filter BrowserSettingsViewTests
```

Expected: failures report the missing `ChooserTargetRow` and the old detail rendering.

- [ ] **Step 3: Create the focused target-row component**

Create `ChooserTargetRow.swift` with this shape:

```swift
import AppKit
import SwiftUI

struct ChooserTargetRow: View {
  let label: String
  let shortcut: ChooserShortcut?
  let applicationURL: URL?
  let isIndented: Bool
  let isSelected: Bool
  let metrics: ChooserMetrics
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if let applicationURL {
          applicationIcon(applicationURL)
        } else if isIndented {
          Color.clear.frame(width: 22, height: 1)
        }

        Text(label)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
        if let shortcut {
          Text(shortcut.label)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
      }
      .contentShape(Rectangle())
      .padding(.horizontal, metrics.rowHorizontalPadding)
      .padding(.vertical, metrics.rowVerticalPadding)
      .background(selectionFill, in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(
            isSelected ? Color.accentColor.opacity(0.55) : .clear,
            lineWidth: 1
          )
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  private var selectionFill: Color {
    if isSelected { return Color.accentColor.opacity(0.16) }
    if isHovering { return Color.accentColor.opacity(0.07) }
    return .clear
  }

  private func applicationIcon(_ url: URL) -> some View {
    let image = NSWorkspace.shared.icon(forFile: url.path)
    image.size = NSSize(width: 22, height: 22)
    return Image(nsImage: image).resizable().frame(width: 22, height: 22)
  }
}
```

Keep hover transitions immediate; do not add animation in this change.

- [ ] **Step 4: Convert `ChooserView` to density metrics and one-line rows**

Add `density: ChooserDensity = .compact` to the initializer and use:

```swift
private var metrics: ChooserMetrics { density.metrics }
```

Replace fixed values in the outer stack, group stack, padding, headers, width, and footer control sizing with `metrics`. The outer width becomes:

```swift
.frame(width: metrics.contentWidth)
```

Replace the current row button with:

```swift
ChooserTargetRow(
  label: target.label,
  shortcut: row.shortcut,
  applicationURL: indented ? nil : application.applicationURL,
  isIndented: indented,
  isSelected: selected,
  metrics: metrics,
  action: { onSelection(row.targetID) }
)
```

Delete `detail(for:application:indented:)`. Keep group headers, `.id(row.targetID)`, `ViewThatFits`, `ScrollViewReader`, and `scrollTo` unchanged.

- [ ] **Step 5: Confirm fitting height still grows and caps**

Run:

```bash
swift test --filter BrowserSettingsViewTests
swift test --filter ChooserPanelControllerTests
```

Expected: source-structure tests pass, six rows are taller than one row, oversized lists cap at the visible-screen maximum, and the compact width is 340.

- [ ] **Step 6: Run the complete warning-as-errors suite**

Run:

```bash
swift test -Xswiftc -warnings-as-errors
```

Expected: all XCTest and Swift Testing cases pass with zero warnings promoted to errors.

- [ ] **Step 7: Build the production app**

Run:

```bash
bash scripts/build-app.sh
```

Expected: exit code 0 and a fresh ignored `build/PickVia.app` bundle.

- [ ] **Step 8: Perform a focused manual smoke check**

Launch the fresh app bundle, use `Test Browser Chooser…`, and verify:

- rows have one text line;
- the selected row has a flat tint and thin border with no shadow halo;
- hover is lighter than selection;
- Compact fits materially more rows;
- Balanced and Spacious apply on the next chooser opening;
- shortcuts, arrows, Return, Escape, Copy, Settings, and Cancel work; and
- Browser Settings shows browser-default private targets enabled and named-profile private targets disabled after migration.

- [ ] **Step 9: Commit Task 4**

```bash
git add Sources/PickVia/Chooser/ChooserTargetRow.swift Sources/PickVia/Chooser/ChooserView.swift Tests/PickViaTests/BrowserSettingsViewTests.swift Tests/PickViaTests/ChooserModelsTests.swift
git commit -m "feat: polish chooser rows and selection"
```

---

## Final Verification

- [ ] Run `git diff --check` and confirm no whitespace errors.
- [ ] Run `swift test -Xswiftc -warnings-as-errors` and confirm the complete suite passes.
- [ ] Run `bash scripts/build-app.sh` and confirm `build/PickVia.app` is produced but untracked.
- [ ] Run `git status --short --branch` and confirm only the intended plan checkbox updates remain, if checkbox tracking was committed separately.
- [ ] Review the final diff against `docs/specs/2026-07-21-chooser-ui-polish-design.md`, checking every acceptance criterion explicitly.
