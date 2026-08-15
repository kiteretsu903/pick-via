import AppKit
import Foundation
import PickViaCore
import XCTest

@testable import PickVia

@MainActor
final class AppDelegateTests: XCTestCase {
  func testBecomingActiveRefreshesDefaultHandlerStatusAndRetriesProfileAccess() throws {
    let defaults = AppDelegateDefaultBrowserStub()
    let presenter = AppDelegateProfileAccessPresenterSpy()
    let model = makeModel(defaultBrowser: defaults)
    try model.load()
    let delegate = AppDelegate(
      model: model,
      profileAccessPresenter: presenter,
      openSettings: {}
    )

    delegate.applicationDidBecomeActive(
      Notification(name: NSApplication.didBecomeActiveNotification))

    XCTAssertEqual(defaults.statusCallCount, 2)
    XCTAssertEqual(presenter.environmentDidChangeCallCount, 1)
  }

  func testWillBecomeActivePreparesVisibleWindowsForCurrentSpace() {
    let windowSpaceCoordinator = AppWindowSpaceCoordinatorSpy()
    let delegate = AppDelegate(
      model: makeModel(),
      windowSpaceCoordinator: windowSpaceCoordinator,
      openSettings: {}
    )

    delegate.applicationWillBecomeActive(
      Notification(name: NSApplication.willBecomeActiveNotification)
    )

    XCTAssertEqual(windowSpaceCoordinator.prepareVisibleWindowsForActivationCallCount, 1)
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
    let scheduler = AppDelegateLaunchSchedulerSpy()
    var destinationWhenOpened: SettingsDestination?
    let presenter = AppDelegateProfileAccessPresenterSpy()
    let prewarmer = AppDelegateChooserPrewarmerSpy()
    let delegate = AppDelegate(
      model: model,
      navigation: navigation,
      profileAccessPresenter: presenter,
      chooserPrewarmer: prewarmer,
      launchScheduler: scheduler,
      openSettings: { destinationWhenOpened = navigation.destination }
    )

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    XCTAssertEqual(destinationWhenOpened, .browsers)
    XCTAssertEqual(presenter.requestIfPendingCallCount, 0)
    XCTAssertEqual(scheduler.scheduleCallCount, 0)
    XCTAssertEqual(prewarmer.prepareCallCount, 0)
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

  func testLaunchDefersPendingProfileAccessUntilNextMainRunLoopTurn() throws {
    let scheduler = AppDelegateLaunchSchedulerSpy()
    var lifecycleEvents: [String] = []
    let presenter = AppDelegateProfileAccessPresenterSpy {
      lifecycleEvents.append("profile-access")
    }
    let prewarmer = AppDelegateChooserPrewarmerSpy {
      lifecycleEvents.append("prewarm")
    }
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
      chooserPrewarmer: prewarmer,
      launchScheduler: scheduler,
      openSettings: {}
    )

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    XCTAssertEqual(scheduler.scheduleCallCount, 1)
    XCTAssertEqual(presenter.requestIfPendingCallCount, 0)
    XCTAssertEqual(prewarmer.prepareCallCount, 0)

    scheduler.runNext()

    XCTAssertEqual(presenter.requestIfPendingCallCount, 1)
    XCTAssertTrue(presenter.lastModel === model)
    XCTAssertEqual(prewarmer.prepareCallCount, 1)
    XCTAssertEqual(prewarmer.lastApplications, model.browsers)
    XCTAssertEqual(prewarmer.lastTargets, model.targets)
    XCTAssertEqual(lifecycleEvents, ["prewarm", "profile-access"])
  }

  func testLaunchKeepsProfileAccessPendingDuringOnboardingReview() throws {
    let presenter = AppDelegateProfileAccessPresenterSpy()
    let scheduler = AppDelegateLaunchSchedulerSpy()
    let prewarmer = AppDelegateChooserPrewarmerSpy()
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
      chooserPrewarmer: prewarmer,
      launchScheduler: scheduler,
      openSettings: {}
    )

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    XCTAssertEqual(model.profileAccessPresentation, .automaticPending)
    XCTAssertEqual(presenter.requestIfPendingCallCount, 0)
    XCTAssertEqual(scheduler.scheduleCallCount, 1)
    XCTAssertEqual(prewarmer.prepareCallCount, 0)

    scheduler.runNext()

    XCTAssertEqual(prewarmer.prepareCallCount, 1)
    XCTAssertEqual(prewarmer.lastApplications, model.browsers)
    XCTAssertEqual(prewarmer.lastTargets, model.targets)
    XCTAssertEqual(presenter.requestIfPendingCallCount, 0)
  }

  func testLaunchPrewarmsWithoutPendingProfileAccess() throws {
    let presenter = AppDelegateProfileAccessPresenterSpy()
    let scheduler = AppDelegateLaunchSchedulerSpy()
    let prewarmer = AppDelegateChooserPrewarmerSpy()
    let model = makeModel(
      preferences: AppDelegatePreferencesStub(onboardingStep: 3)
    )
    try model.load()
    let delegate = AppDelegate(
      model: model,
      profileAccessPresenter: presenter,
      chooserPrewarmer: prewarmer,
      launchScheduler: scheduler,
      openSettings: {}
    )

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    XCTAssertEqual(model.profileAccessPresentation, .idle)
    XCTAssertEqual(presenter.requestIfPendingCallCount, 0)
    XCTAssertEqual(scheduler.scheduleCallCount, 1)
    XCTAssertEqual(prewarmer.prepareCallCount, 0)

    scheduler.runNext()

    XCTAssertEqual(prewarmer.prepareCallCount, 1)
    XCTAssertEqual(prewarmer.lastApplications, model.browsers)
    XCTAssertEqual(prewarmer.lastTargets, model.targets)
    XCTAssertEqual(presenter.requestIfPendingCallCount, 0)
  }

  func testOpenURLsPassesEachURLThroughModelValidation() throws {
    let routing = AppDelegateRoutingSpy()
    let model = makeModel(routing: routing)
    let delegate = AppDelegate(model: model, openSettings: {})
    let http = try XCTUnwrap(URL(string: "http://example.com/one"))
    let file = URL(fileURLWithPath: "/tmp/not-a-web-link")
    let https = try XCTUnwrap(URL(string: "https://example.com/two"))
    let mailto = try XCTUnwrap(URL(string: "mailto:person@example.com"))

    delegate.application(NSApplication.shared, open: [http, file, https, mailto])

    XCTAssertEqual(routing.acceptedURLs, [http, https, mailto])
  }

  func testInfoPlistRegistersExactlySupportedSchemes() throws {
    let schemes = try infoPlistURLSchemes()
    XCTAssertEqual(Set(schemes), ["http", "https", "mailto"])
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

  private func infoPlistURLSchemes() throws -> [String] {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(contentsOf: repositoryRoot.appending(path: "Support/Info.plist"))
    let plist = try XCTUnwrap(
      try PropertyListSerialization.propertyList(
        from: data,
        options: [],
        format: nil
      ) as? [String: Any]
    )
    let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
    return urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
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
private final class AppDelegateDefaultBrowserStub: DefaultHandlerServicing {
  private(set) var statusCallCount = 0
  func status() -> DefaultHandlerStatus {
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
  private(set) var environmentDidChangeCallCount = 0
  private(set) weak var lastModel: AppModel?
  private let onRequestIfPending: @MainActor () -> Void

  init(onRequestIfPending: @escaping @MainActor () -> Void = {}) {
    self.onRequestIfPending = onRequestIfPending
  }

  func request(model: AppModel) {
    lastModel = model
  }

  func requestIfPending(model: AppModel) {
    requestIfPendingCallCount += 1
    lastModel = model
    onRequestIfPending()
  }

  func environmentDidChange() {
    environmentDidChangeCallCount += 1
  }
  func dismiss() {}
}

@MainActor
private final class AppDelegateChooserPrewarmerSpy: ChooserPrewarming {
  private(set) var prepareCallCount = 0
  private(set) var lastApplications: [BrowserApplication]?
  private(set) var lastTargets: [BrowserTarget]?
  private let onPrepare: @MainActor () -> Void

  init(onPrepare: @escaping @MainActor () -> Void = {}) {
    self.onPrepare = onPrepare
  }

  func prepare(applications: [BrowserApplication], targets: [BrowserTarget]) {
    prepareCallCount += 1
    lastApplications = applications
    lastTargets = targets
    onPrepare()
  }
}

@MainActor
private final class AppDelegateLaunchSchedulerSpy: AppLaunchScheduling {
  private(set) var scheduleCallCount = 0
  private var scheduledAction: (@MainActor @Sendable () -> Void)?

  func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
    scheduleCallCount += 1
    scheduledAction = action
  }

  func runNext() {
    let action = scheduledAction
    scheduledAction = nil
    action?()
  }
}

@MainActor
private final class AppWindowSpaceCoordinatorSpy: AppWindowSpaceCoordinating {
  private(set) var prepareVisibleWindowsForActivationCallCount = 0

  func prepareVisibleWindowsForActivation() {
    prepareVisibleWindowsForActivationCallCount += 1
  }
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
