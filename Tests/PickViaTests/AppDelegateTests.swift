import AppKit
import Foundation
import PickViaCore
import XCTest

@testable import PickVia

@MainActor
final class AppDelegateTests: XCTestCase {
  func testBecomingActiveRefreshesDefaultHandlerStatus() throws {
    let defaults = AppDelegateDefaultBrowserStub()
    let model = makeModel(defaultBrowser: defaults)
    try model.load()
    let delegate = AppDelegate(model: model, openSettings: {})

    delegate.applicationDidBecomeActive(
      Notification(name: NSApplication.didBecomeActiveNotification))

    XCTAssertEqual(defaults.statusCallCount, 2)
  }

  func testRecoveredConfigurationOpensBrowserSettingsAfterLaunch() throws {
    let model = AppModel(
      configStore: AppDelegateConfigStoreStub(
        outcome: .recoveredCorruption(.initial)
      ),
      browserCatalog: AppDelegateCatalogStub(),
      preferences: AppDelegatePreferencesStub(),
      defaultBrowser: AppDelegateDefaultBrowserStub(),
      loginItem: AppDelegateLoginItemStub(),
      routing: AppDelegateRoutingSpy()
    )
    try model.load()
    let navigation = SettingsNavigation()
    var destinationWhenOpened: SettingsDestination?
    let presenter = AppDelegateProfileAccessPresenterSpy()
    let delegate = AppDelegate(
      model: model,
      navigation: navigation,
      profileAccessPresenter: presenter,
      openSettings: { destinationWhenOpened = navigation.destination }
    )

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    XCTAssertEqual(destinationWhenOpened, .browsers)
    XCTAssertEqual(presenter.requestIfPendingCallCount, 0)
  }

  func testClosingRecoveredSettingsQueuesAutomaticProfileAccessAfterReview() throws {
    let model = AppModel(
      configStore: AppDelegateConfigStoreStub(
        outcome: .recoveredCorruption(.initial)
      ),
      browserCatalog: AppDelegateCatalogStub(
        scanResult: AppDelegateFixtures.profileAccessRequiredScan
      ),
      preferences: AppDelegatePreferencesStub(onboardingStep: 3),
      defaultBrowser: AppDelegateDefaultBrowserStub(),
      loginItem: AppDelegateLoginItemStub(),
      routing: AppDelegateRoutingSpy()
    )
    try model.load()
    let presenter = AppDelegateProfileAccessPresenterSpy()
    let delegate = AppDelegate(
      model: model,
      profileAccessPresenter: presenter,
      openSettings: {}
    )
    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )
    XCTAssertEqual(presenter.requestIfPendingCallCount, 0)

    settingsDidClose(model: model, profileAccessPresenter: presenter)

    XCTAssertEqual(model.configurationRecovery, .none)
    XCTAssertEqual(model.profileAccessPresentation, .automaticPending)
    XCTAssertEqual(presenter.requestIfPendingCallCount, 1)
    XCTAssertTrue(presenter.lastModel === model)
  }

  func testLaunchRequestsPendingProfileAccessAfterOnboardingReview() throws {
    let presenter = AppDelegateProfileAccessPresenterSpy()
    let model = makeModel(
      catalog: AppDelegateCatalogStub(
        scanResult: AppDelegateFixtures.profileAccessRequiredScan
      ),
      preferences: AppDelegatePreferencesStub(onboardingStep: 3)
    )
    try model.load()
    let delegate = AppDelegate(
      model: model,
      profileAccessPresenter: presenter,
      openSettings: {}
    )

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    XCTAssertEqual(presenter.requestIfPendingCallCount, 1)
    XCTAssertTrue(presenter.lastModel === model)
  }

  func testLaunchKeepsProfileAccessPendingDuringOnboardingReview() throws {
    let presenter = AppDelegateProfileAccessPresenterSpy()
    let model = makeModel(
      catalog: AppDelegateCatalogStub(
        scanResult: AppDelegateFixtures.profileAccessRequiredScan
      ),
      preferences: AppDelegatePreferencesStub(onboardingStep: 2)
    )
    try model.load()
    let delegate = AppDelegate(
      model: model,
      profileAccessPresenter: presenter,
      openSettings: {}
    )

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    XCTAssertEqual(model.profileAccessPresentation, .automaticPending)
    XCTAssertEqual(presenter.requestIfPendingCallCount, 0)
  }
  func testOpenURLsPassesEachURLThroughModelValidation() throws {
    let routing = AppDelegateRoutingSpy()
    let model = makeModel(routing: routing)
    let delegate = AppDelegate(model: model, openSettings: {})
    let http = try XCTUnwrap(URL(string: "http://example.com/one"))
    let file = URL(fileURLWithPath: "/tmp/not-a-web-link")
    let https = try XCTUnwrap(URL(string: "https://example.com/two"))

    delegate.application(NSApplication.shared, open: [http, file, https])

    XCTAssertEqual(routing.acceptedURLs, [http, https])
  }

  func testReopenOpensSettingsAndReportsHandled() {
    var openSettingsCallCount = 0
    let navigation = SettingsNavigation(destination: .browsers)
    var destinationWhenOpened: SettingsDestination?
    let delegate = AppDelegate(
      model: makeModel(),
      navigation: navigation,
      openSettings: {
        openSettingsCallCount += 1
        destinationWhenOpened = navigation.destination
      }
    )

    let handled = delegate.applicationShouldHandleReopen(
      NSApplication.shared,
      hasVisibleWindows: false
    )

    XCTAssertTrue(handled)
    XCTAssertEqual(openSettingsCallCount, 1)
    XCTAssertEqual(destinationWhenOpened, .general)
  }

  func testSettingsNavigationActionUsesInstalledSceneOpenerForBrowsers() {
    let navigation = SettingsNavigation()
    let opener = SettingsSceneOpener()
    var openCount = 0
    opener.install { openCount += 1 }
    let delegate = AppDelegate(
      model: makeModel(),
      navigation: navigation,
      settingsSceneOpener: opener,
      openSettings: { opener.open() }
    )

    let handled = delegate.settingsNavigationAction.open(.browsers)

    XCTAssertTrue(handled)
    XCTAssertEqual(navigation.destination, .browsers)
    XCTAssertEqual(openCount, 1)
  }

  func testReopenCannotOpenSettingsWhileProfileAccessPanelIsPresented() throws {
    var openSettingsCallCount = 0
    let model = makeModel(
      catalog: AppDelegateCatalogStub(
        scanResult: AppDelegateFixtures.profileAccessRequiredScan
      )
    )
    try model.load()
    model.profileAccessDidPresent()
    let delegate = AppDelegate(
      model: model,
      openSettings: { openSettingsCallCount += 1 }
    )

    let activeResult = delegate.applicationShouldHandleReopen(
      NSApplication.shared,
      hasVisibleWindows: false
    )
    XCTAssertFalse(activeResult)
    XCTAssertEqual(openSettingsCallCount, 0)

    model.closeProfileAccess()
    let closingResult = delegate.applicationShouldHandleReopen(
      NSApplication.shared,
      hasVisibleWindows: false
    )
    XCTAssertFalse(closingResult)
    XCTAssertEqual(openSettingsCallCount, 0)

    model.profileAccessDidDismiss()
    let dismissedResult = delegate.applicationShouldHandleReopen(
      NSApplication.shared,
      hasVisibleWindows: false
    )
    XCTAssertTrue(dismissedResult)
    XCTAssertEqual(openSettingsCallCount, 1)
  }

  func testAppSettingsCommandWaitsForExactProfileAccessDismissal() throws {
    var openSettingsCallCount = 0
    let navigation = SettingsNavigation(destination: .browsers)
    var destinationWhenOpened: SettingsDestination?
    let model = makeModel(
      catalog: AppDelegateCatalogStub(
        scanResult: AppDelegateFixtures.profileAccessRequiredScan
      )
    )
    try model.load()
    model.profileAccessDidPresent()
    let delegate = AppDelegate(
      model: model,
      navigation: navigation,
      openSettings: {
        openSettingsCallCount += 1
        destinationWhenOpened = navigation.destination
      }
    )

    XCTAssertFalse(delegate.settingsNavigationAction.isEnabled)
    XCTAssertFalse(delegate.settingsNavigationAction.open(.general))
    XCTAssertEqual(openSettingsCallCount, 0)
    XCTAssertEqual(navigation.destination, .browsers)

    model.closeProfileAccess()
    XCTAssertFalse(delegate.settingsNavigationAction.isEnabled)
    XCTAssertFalse(delegate.settingsNavigationAction.open(.general))
    XCTAssertEqual(openSettingsCallCount, 0)

    model.profileAccessDidDismiss()
    XCTAssertTrue(delegate.settingsNavigationAction.isEnabled)
    XCTAssertTrue(delegate.settingsNavigationAction.open(.general))
    XCTAssertEqual(openSettingsCallCount, 1)
    XCTAssertEqual(destinationWhenOpened, .general)
  }

  func testAboutCommandWaitsForExactProfileAccessDismissal() throws {
    var aboutCallCount = 0
    let model = makeModel(
      catalog: AppDelegateCatalogStub(
        scanResult: AppDelegateFixtures.profileAccessRequiredScan
      )
    )
    try model.load()
    model.profileAccessDidPresent()
    let delegate = AppDelegate(
      model: model,
      openSettings: {},
      showAbout: { aboutCallCount += 1 }
    )

    XCTAssertFalse(delegate.aboutAction.isEnabled)
    XCTAssertFalse(delegate.aboutAction.show())
    model.closeProfileAccess()
    XCTAssertFalse(delegate.aboutAction.isEnabled)
    XCTAssertFalse(delegate.aboutAction.show())

    XCTAssertEqual(aboutCallCount, 0)

    model.profileAccessDidDismiss()
    XCTAssertTrue(delegate.aboutAction.isEnabled)
    XCTAssertTrue(delegate.aboutAction.show())

    XCTAssertEqual(aboutCallCount, 1)
  }

  private func makeModel(
    routing: AppDelegateRoutingSpy = AppDelegateRoutingSpy(),
    defaultBrowser: AppDelegateDefaultBrowserStub = AppDelegateDefaultBrowserStub(),
    catalog: AppDelegateCatalogStub = AppDelegateCatalogStub(),
    preferences: AppDelegatePreferencesStub = AppDelegatePreferencesStub()
  ) -> AppModel {
    AppModel(
      configStore: AppDelegateConfigStoreStub(),
      browserCatalog: catalog,
      preferences: preferences,
      defaultBrowser: defaultBrowser,
      loginItem: AppDelegateLoginItemStub(),
      routing: routing
    )
  }
}

private struct AppDelegateConfigStoreStub: ConfigStoring {
  let outcome: ConfigLoadOutcome

  init(outcome: ConfigLoadOutcome = .loaded(.initial)) {
    self.outcome = outcome
  }

  func load() throws -> PickViaConfig { .initial }
  func loadOutcome() -> ConfigLoadOutcome { outcome }
  func save(_ config: PickViaConfig) throws {}
}

private struct AppDelegateCatalogStub: BrowserDiscovering {
  let configuredScanResult: BrowserScanResult

  init(
    scanResult: BrowserScanResult = BrowserScanResult(
      browsers: [], warnings: [], isAuthoritative: true
    )
  ) {
    configuredScanResult = scanResult
  }

  func scan() throws -> [DiscoveredBrowser] { configuredScanResult.browsers }
  func scanResult() -> BrowserScanResult { configuredScanResult }
  func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig {
    config
  }
}

@MainActor
private final class AppDelegatePreferencesStub: PreferencesStoring {
  private let onboardingStep: Int?

  init(onboardingStep: Int? = nil) {
    self.onboardingStep = onboardingStep
  }

  func bool(forKey key: String) -> Bool? { nil }
  func integer(forKey key: String) -> Int? {
    key == "onboardingStep" ? onboardingStep : nil
  }
  func set(_ value: Bool, forKey key: String) {}
  func set(_ value: Int, forKey key: String) {}
}

@MainActor
private final class AppDelegateDefaultBrowserStub: DefaultBrowserServicing {
  private(set) var statusCallCount = 0
  func status() -> DefaultBrowserStatus {
    statusCallCount += 1
    return .unknown
  }
  func requestDefault(for schemes: [String]) async throws {}
}

@MainActor
private final class AppDelegateLoginItemStub: LoginItemServicing {
  var isEnabled: Bool { false }
  func setEnabled(_ enabled: Bool) throws {}
}

@MainActor
private final class AppDelegateRoutingSpy: AppRouting {
  private(set) var acceptedURLs: [URL] = []
  func accept(_ url: URL) { acceptedURLs.append(url) }
  func preview(_ url: URL) {}
}

@MainActor
private final class AppDelegateProfileAccessPresenterSpy: ProfileAccessPresenting {
  private(set) var requestIfPendingCallCount = 0
  private(set) weak var lastModel: AppModel?

  func request(model: AppModel) {
    lastModel = model
  }

  func requestIfPending(model: AppModel) {
    requestIfPendingCallCount += 1
    lastModel = model
  }

  func environmentDidChange() {}
  func dismiss() {}
}

private enum AppDelegateFixtures {
  static let chrome = BrowserApplication(
    id: "com.google.Chrome",
    family: .chromium,
    displayName: "Google Chrome",
    bundleIdentifier: "com.google.Chrome",
    applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
    executableURL: nil,
    isAvailable: true
  )

  static let profileAccessRequiredScan = BrowserScanResult(
    browsers: [
      DiscoveredBrowser(
        application: chrome,
        profiles: [],
        metadataStatus: .accessRequired
      )
    ],
    profileAccessIssues: [.accessRequired(bundleIdentifier: chrome.bundleIdentifier)]
  )
}
