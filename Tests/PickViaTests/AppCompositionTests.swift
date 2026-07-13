import Foundation
import PickViaCore
import XCTest

@testable import PickVia

@MainActor
final class AppCompositionTests: XCTestCase {
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

  init(config: PickViaConfig) {
    self.config = config
  }

  func load() throws -> PickViaConfig { config }
  func save(_ config: PickViaConfig) throws {}
}

private struct CompositionCatalogStub: BrowserDiscovering {
  func scan() throws -> [DiscoveredBrowser] { [] }
  func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig {
    config
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
  private var onSelection: ((BrowserTarget.ID) -> Void)?

  func present(
    request: RoutingRequest,
    applications: [BrowserApplication],
    targets: [BrowserTarget],
    error: LaunchFailure?,
    onSelection: @escaping (BrowserTarget.ID) -> Void,
    onCancel: @escaping () -> Void
  ) {
    presentedRequests.append(request)
    self.onSelection = onSelection
  }

  func dismiss() {
    dismissCallCount += 1
    onSelection = nil
  }

  func select(targetID: BrowserTarget.ID) {
    onSelection?(targetID)
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
}
