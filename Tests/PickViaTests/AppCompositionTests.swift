import Foundation
import PickViaCore
import XCTest

@testable import PickVia

@MainActor
final class AppCompositionTests: XCTestCase {
  func testRoutingUsesAuthoritativeStartupSnapshotWithoutReloadingDisk() throws {
    let chooser = CompositionChooserSpy()
    let stale = PickViaConfig(
      schemaVersion: 1,
      browsers: CompositionFixtures.config.browsers,
      targets: [CompositionFixtures.copyTarget(isEnabled: false)]
    )
    let store = CompositionConfigStore(config: stale)
    let model = AppComposition.makeModel(
      configStore: store,
      browserCatalog: CompositionCatalogStub(
        scanResult: BrowserScanResult(browsers: [], warnings: [], isAuthoritative: true),
        reconciled: CompositionFixtures.config
      ),
      preferences: CompositionPreferencesStub(),
      defaultBrowser: CompositionDefaultBrowserStub(),
      loginItem: CompositionLoginItemStub(),
      chooser: chooser,
      launcher: CompositionLauncherSpy()
    )

    try model.load()
    model.accept(url: URL(string: "https://example.com/current")!)

    XCTAssertEqual(store.loadCallCount, 1)
    XCTAssertEqual(chooser.presentedTargetIDs.last, [CompositionFixtures.target.id])
  }
  func testPreviewDoesNotReplaceActiveLiveRoutingPresentation() throws {
    let chooser = CompositionChooserSpy()
    let model = AppComposition.makeModel(
      configStore: CompositionConfigStore(config: CompositionFixtures.config),
      browserCatalog: CompositionCatalogStub(),
      preferences: CompositionPreferencesStub(),
      defaultBrowser: CompositionDefaultBrowserStub(),
      loginItem: CompositionLoginItemStub(),
      chooser: chooser,
      launcher: CompositionLauncherSpy()
    )
    try model.load()
    let liveURL = try XCTUnwrap(URL(string: "https://example.com/live"))
    let subsequentURL = try XCTUnwrap(URL(string: "https://example.com/subsequent"))

    model.accept(url: liveURL)
    model.previewChooser()

    XCTAssertEqual(chooser.presentedRequests.map(\.url), [liveURL])

    chooser.cancel()
    model.accept(url: subsequentURL)

    XCTAssertEqual(chooser.dismissCallCount, 1)
    XCTAssertEqual(chooser.presentedRequests.map(\.url), [liveURL, subsequentURL])
  }

  func testPreviewSelectionDismissesWithoutLaunchingBrowser() async throws {
    let chooser = CompositionChooserSpy()
    let launcher = CompositionLauncherSpy()
    let model = AppComposition.makeModel(
      configStore: CompositionConfigStore(config: CompositionFixtures.config),
      browserCatalog: CompositionCatalogStub(),
      preferences: CompositionPreferencesStub(),
      defaultBrowser: CompositionDefaultBrowserStub(),
      loginItem: CompositionLoginItemStub(),
      chooser: chooser,
      launcher: launcher
    )
    try model.load()

    model.previewChooser()
    chooser.select(targetID: CompositionFixtures.target.id)
    await Task.yield()

    XCTAssertEqual(
      chooser.presentedRequests.map(\.url),
      [
        URL(string: "https://pickvia.invalid/chooser-preview")!
      ])
    XCTAssertEqual(chooser.dismissCallCount, 1)
    let launchCount = await launcher.launchCount
    XCTAssertEqual(launchCount, 0)
  }

  func testLiveRoutingPresentationReplacesIdlePreview() throws {
    let chooser = CompositionChooserSpy()
    let model = AppComposition.makeModel(
      configStore: CompositionConfigStore(config: CompositionFixtures.config),
      browserCatalog: CompositionCatalogStub(),
      preferences: CompositionPreferencesStub(),
      defaultBrowser: CompositionDefaultBrowserStub(),
      loginItem: CompositionLoginItemStub(),
      chooser: chooser,
      launcher: CompositionLauncherSpy()
    )
    try model.load()
    let liveURL = try XCTUnwrap(URL(string: "https://example.com/live-priority"))

    model.previewChooser()
    model.accept(url: liveURL)

    XCTAssertEqual(
      chooser.presentedRequests.map(\.url),
      [
        URL(string: "https://pickvia.invalid/chooser-preview")!,
        liveURL,
      ])
    chooser.cancel()
    XCTAssertEqual(chooser.dismissCallCount, 1)
  }

  func testAppModelURLPreferenceIsResolvedByChooserForEachPreview() throws {
    let preferences = CompositionPreferencesStub()
    let chooser = ChooserPanelController(
      showsURLProvider: { preferences.bool(forKey: PreferenceKey.showsURLInChooser) ?? true }
    )
    let model = AppComposition.makeModel(
      configStore: CompositionConfigStore(config: CompositionFixtures.config),
      browserCatalog: CompositionCatalogStub(),
      preferences: preferences,
      defaultBrowser: CompositionDefaultBrowserStub(),
      loginItem: CompositionLoginItemStub(),
      chooser: chooser,
      launcher: CompositionLauncherSpy()
    )
    try model.load()

    model.previewChooser()
    XCTAssertTrue(chooser.showsURLForCurrentPresentation)
    chooser.dismiss()

    model.showsURLInChooser = false
    model.previewChooser()
    XCTAssertFalse(chooser.showsURLForCurrentPresentation)
    chooser.dismiss()
  }
}

private final class CompositionConfigStore: ConfigStoring, @unchecked Sendable {
  let config: PickViaConfig
  private(set) var loadCallCount = 0

  init(config: PickViaConfig) {
    self.config = config
  }

  func load() throws -> PickViaConfig {
    loadCallCount += 1
    return config
  }
  func save(_ config: PickViaConfig) throws {}
}

private struct CompositionCatalogStub: BrowserDiscovering {
  let configuredScanResult: BrowserScanResult
  let reconciled: PickViaConfig?

  init(
    scanResult: BrowserScanResult = BrowserScanResult(
      browsers: [], warnings: [], isAuthoritative: false),
    reconciled: PickViaConfig? = nil
  ) {
    self.configuredScanResult = scanResult
    self.reconciled = reconciled
  }

  func scan() throws -> [DiscoveredBrowser] { [] }
  func scanResult() -> BrowserScanResult { configuredScanResult }
  func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig {
    reconciled ?? config
  }
}

@MainActor
private final class CompositionPreferencesStub: PreferencesStoring {
  private var booleans: [String: Bool] = [:]

  func bool(forKey key: String) -> Bool? { booleans[key] }
  func integer(forKey key: String) -> Int? { nil }
  func set(_ value: Bool, forKey key: String) { booleans[key] = value }
  func set(_ value: Int, forKey key: String) {}
}

@MainActor
private final class CompositionDefaultBrowserStub: DefaultBrowserServicing {
  func status() -> DefaultBrowserStatus { .unknown }
  func requestDefault(for schemes: [String]) async throws {}
}

@MainActor
private final class CompositionLoginItemStub: LoginItemServicing {
  var isEnabled: Bool { false }
  func setEnabled(_ enabled: Bool) throws {}
}

@MainActor
private final class CompositionChooserSpy: ChooserPresenting {
  private(set) var presentedRequests: [RoutingRequest] = []
  private(set) var dismissCallCount = 0
  private(set) var presentedTargetIDs: [[BrowserTarget.ID]] = []
  private var onSelection: ((BrowserTarget.ID) -> Void)?
  private var onCancel: (() -> Void)?

  func present(
    request: RoutingRequest,
    applications: [BrowserApplication],
    targets: [BrowserTarget],
    error: LaunchFailure?,
    onSelection: @escaping (BrowserTarget.ID) -> Void,
    onCancel: @escaping () -> Void
  ) {
    presentedRequests.append(request)
    presentedTargetIDs.append(targets.map(\.id))
    self.onSelection = onSelection
    self.onCancel = onCancel
  }

  func dismiss() {
    dismissCallCount += 1
    onSelection = nil
    onCancel = nil
  }

  func select(targetID: BrowserTarget.ID) {
    onSelection?(targetID)
  }

  func cancel() {
    onCancel?()
  }
}

private actor CompositionLauncherSpy: BrowserLaunching {
  private(set) var launchCount = 0

  func launch(
    url: URL,
    application: BrowserApplication,
    target: BrowserTarget
  ) async throws {
    launchCount += 1
  }
}

private enum CompositionFixtures {
  static let browser = BrowserApplication(
    id: "com.google.Chrome",
    family: .chromium,
    displayName: "Google Chrome",
    bundleIdentifier: "com.google.Chrome",
    applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
    executableURL: URL(
      fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    isAvailable: true
  )
  static let target = BrowserTarget(
    id: "work",
    browserID: browser.id,
    label: "Work",
    profileIdentifier: "Profile 1",
    profileDisplayName: "Work",
    mode: .normal,
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: .available
  )
  static let config = PickViaConfig(
    schemaVersion: 1,
    browsers: [browser],
    targets: [target]
  )

  static func copyTarget(isEnabled: Bool) -> BrowserTarget {
    BrowserTarget(
      id: target.id,
      browserID: target.browserID,
      label: target.label,
      profileIdentifier: target.profileIdentifier,
      profileDisplayName: target.profileDisplayName,
      mode: target.mode,
      isEnabled: isEnabled,
      sortOrder: target.sortOrder,
      origin: target.origin,
      availability: target.availability
    )
  }
}
