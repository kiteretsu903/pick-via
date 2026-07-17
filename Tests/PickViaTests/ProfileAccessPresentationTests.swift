import AppKit
import Foundation
import PickViaCore
import SwiftUI
import XCTest

@testable import PickVia

@MainActor
final class ProfileAccessPresentationTests: XCTestCase {
  func testPanelDismissalCancelsOutstandingFolderSelectionAndIgnoresLateResult() async throws {
    let selector = PresentationFolderSelectorSpy()
    let selectionCoordinator = ProfileAccessWizardSelectionCoordinator(folderSelector: selector)
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    let presenter = ProfileAccessPanelController(
      driver: driver,
      selectionCoordinator: selectionCoordinator
    )
    let model = try ProfileAccessModelFixture.automaticPending()
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )
    var selectedRoots: [URL] = []
    presenter.requestIfPending(model: model)
    XCTAssertTrue(
      selectionCoordinator.selectRoot(for: chrome) { root in
        selectedRoots.append(root)
      }
    )
    await selector.waitUntilSelectionBegins()

    presenter.dismiss()

    XCTAssertEqual(selector.cancelCallCount, 1)
    selector.resolveSelection(with: URL(fileURLWithPath: "/chosen/Chrome"))
    for _ in 0..<100 where selectionCoordinator.isSelectionInFlight {
      await Task.yield()
    }
    XCTAssertFalse(selectionCoordinator.isSelectionInFlight)
    XCTAssertTrue(selectedRoots.isEmpty)
  }

  func testEarlySheetRetryRemainsQueuedUntilPostDetachSignalThenPresentsOnce() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: false)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending()
    presenter.requestIfPending(model: model)

    presenter.environmentDidChange()
    XCTAssertEqual(driver.presentCallCount, 0)

    driver.canPresent = true
    driver.signalEnvironmentDidChange()
    driver.signalEnvironmentDidChange()

    XCTAssertEqual(driver.presentCallCount, 1)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
  }

  func testAppKitDriverSignalsEnvironmentChangeAfterSheetEndNotification() async {
    let notificationCenter = NotificationCenter()
    let driver = AppKitProfileAccessPanelDriver(notificationCenter: notificationCenter)
    let signal = expectation(description: "post-detachment environment signal")
    driver.environmentDidChangeHandler = { signal.fulfill() }

    notificationCenter.post(name: NSWindow.didEndSheetNotification, object: nil)

    await fulfillment(of: [signal], timeout: 1)
  }

  func testAppKitDriverSignalsEnvironmentChangeAfterSettingsWindowCloses() async {
    let notificationCenter = NotificationCenter()
    let driver = AppKitProfileAccessPanelDriver(notificationCenter: notificationCenter)
    let signal = expectation(description: "post-settings environment signal")
    driver.environmentDidChangeHandler = { signal.fulfill() }

    notificationCenter.post(name: NSWindow.willCloseNotification, object: nil)

    await fulfillment(of: [signal], timeout: 1)
  }

  func testAppKitDriverCannotPresentWhileLogicalChooserPresentationIsActive() {
    let driver = AppKitProfileAccessPanelDriver(isChooserActive: { true })
    driver.attachWizardViewFactory { _ in AnyView(EmptyView()) }

    XCTAssertFalse(driver.canPresent)
  }

  func testAppKitDriverPresentsPanelOnActiveSpace() throws {
    let driver = AppKitProfileAccessPanelDriver()
    driver.attachWizardViewFactory { _ in AnyView(EmptyView()) }
    let model = try ProfileAccessModelFixture.automaticPending()

    driver.present(model: model, onClose: {})
    defer { driver.dismissAndRestoreWindows() }

    let panel = try XCTUnwrap(
      NSApp.windows.first(where: { $0.title == "Browser Profile Access" }) as? NSPanel
    )
    XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
    XCTAssertTrue(panel.isVisible)
  }

  func testProfileAccessPanelOriginCentersPanelInVisibleFrame() {
    let origin = profileAccessPanelOrigin(
      panelSize: NSSize(width: 620, height: 440),
      visibleFrame: NSRect(x: 100, y: 50, width: 1_200, height: 800)
    )

    XCTAssertEqual(origin.x, 390)
    XCTAssertEqual(origin.y, 230)
  }

  func testAutomaticRequestWaitsUntilOnboardingReviewCompletes() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending(onboardingStep: 2)

    presenter.requestIfPending(model: model)

    XCTAssertEqual(driver.presentCallCount, 0)
    XCTAssertEqual(model.profileAccessPresentation, .automaticPending)
  }

  func testPendingWizardWaitsForChooserThenPresentsOnce() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: false)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending()

    presenter.requestIfPending(model: model)
    presenter.requestIfPending(model: model)
    XCTAssertEqual(driver.presentCallCount, 0)

    driver.canPresent = true
    presenter.environmentDidChange()

    XCTAssertEqual(driver.presentCallCount, 1)
    XCTAssertEqual(driver.hideCompetingWindowsCallCount, 1)
    XCTAssertEqual(model.profileAccessPresentation, .presented)

    presenter.environmentDidChange()
    XCTAssertEqual(driver.presentCallCount, 1)
  }

  func testManageWhileAutomaticRequestIsBlockedPreservesAutomaticFlow() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: false)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending()
    presenter.requestIfPending(model: model)

    model.openProfileAccessManager()
    presenter.request(model: model)

    XCTAssertEqual(model.profileAccessPresentation, .automaticPending)
    XCTAssertTrue(model.hasUnresolvedAutomaticProfileAccess)
    XCTAssertFalse(model.canRequestDefaultBrowser)
    XCTAssertEqual(driver.presentCallCount, 0)

    driver.canPresent = true
    driver.signalEnvironmentDidChange()

    XCTAssertEqual(driver.presentCallCount, 1)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
    XCTAssertTrue(model.hasUnresolvedAutomaticProfileAccess)
  }

  func testHiddenActiveChooserKeepsManagerAndRescanQueuedUntilChooserLifecycleEnds()
    async throws
  {
    let relay = ProfileAccessLifecycleRelay()
    let chooser = ChooserPanelController(
      openBrowserSettings: {},
      onPresentationChange: { _ in relay.handler?() }
    )
    let driver = ProfileAccessPanelDriverSpy(canPresent: { !chooser.hasActivePresentation })
    let presenter = ProfileAccessPanelController(driver: driver)
    relay.handler = { presenter.environmentDidChange() }
    let model = try ProfileAccessModelFixture.automaticPending()
    chooser.present(
      request: RoutingRequest(url: URL(string: "https://example.com/hidden")!),
      applications: [],
      targets: [],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    chooser.showBrowserSettings()
    XCTAssertTrue(chooser.hasActivePresentation)

    try model.userRequestedRescan()
    presenter.requestIfPending(model: model)
    model.openProfileAccessManager()
    presenter.request(model: model)
    model.settingsDidClose()
    presenter.environmentDidChange()

    XCTAssertEqual(driver.presentCallCount, 0)

    chooser.dismiss()
    await Task.yield()

    XCTAssertEqual(driver.presentCallCount, 1)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
  }

  func testCloseRestoresOrdinaryWindowsExactlyOnce() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending()
    presenter.requestIfPending(model: model)

    driver.closePresentedPanel()
    presenter.dismiss()

    XCTAssertEqual(driver.dismissAndRestoreWindowsCallCount, 1)
    XCTAssertEqual(model.profileAccessPresentation, .suppressedForProcess)
  }

  func testDismissRestoresOrdinaryWindowsForFinishOrSkip() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending()
    presenter.requestIfPending(model: model)

    presenter.dismiss()

    XCTAssertEqual(driver.dismissAndRestoreWindowsCallCount, 1)
  }

  func testPhysicalSurfaceRemainsExclusiveAfterSkipUntilPresenterRestoresWindows() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending()
    presenter.requestIfPending(model: model)

    XCTAssertTrue(model.isProfileAccessSurfaceActive)
    XCTAssertFalse(model.canPresentOrdinaryAppSurface)

    model.skipProfileAccess()

    XCTAssertEqual(model.profileAccessPresentation, .suppressedForProcess)
    XCTAssertTrue(model.isProfileAccessSurfaceActive)
    XCTAssertFalse(model.canPresentOrdinaryAppSurface)

    presenter.dismiss()

    XCTAssertEqual(driver.dismissAndRestoreWindowsCallCount, 1)
    XCTAssertFalse(model.isProfileAccessSurfaceActive)
    XCTAssertTrue(model.canPresentOrdinaryAppSurface)

    presenter.dismiss()
    XCTAssertEqual(driver.dismissAndRestoreWindowsCallCount, 1)
    XCTAssertFalse(model.isProfileAccessSurfaceActive)
  }

  func testControllerDeinitRestoresSurfaceAndFlushesDeferredURLExactlyOnce() throws {
    var lifecycleEvents: [String] = []
    let routing = ProfileAccessRoutingSpy(
      onAccept: { lifecycleEvents.append("accept:\($0.absoluteString)") }
    )
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    driver.onDismissAndRestore = { lifecycleEvents.append("restore") }
    let model = try ProfileAccessModelFixture.automaticPending(routing: routing)
    let url = URL(string: "https://example.com/controller-lifetime")!
    weak var releasedController: ProfileAccessPanelController?

    do {
      let controller = ProfileAccessPanelController(driver: driver)
      releasedController = controller
      controller.requestIfPending(model: model)
      model.accept(url: url)

      XCTAssertTrue(model.isProfileAccessSurfaceActive)
      XCTAssertTrue(routing.acceptedURLs.isEmpty)
    }

    XCTAssertNil(releasedController)
    XCTAssertEqual(driver.dismissAndRestoreWindowsCallCount, 1)
    XCTAssertFalse(model.isProfileAccessSurfaceActive)
    XCTAssertEqual(routing.acceptedURLs, [url])
    XCTAssertEqual(
      lifecycleEvents,
      ["restore", "accept:\(url.absoluteString)"]
    )

    driver.closePresentedPanel()
    model.profileAccessDidDismiss()

    XCTAssertEqual(driver.dismissAndRestoreWindowsCallCount, 1)
    XCTAssertEqual(routing.acceptedURLs, [url])
    XCTAssertEqual(
      lifecycleEvents,
      ["restore", "accept:\(url.absoluteString)"]
    )
  }

  func testProgrammaticRescanCannotOverlapAnAlreadyPresentedPanel() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending()
    presenter.requestIfPending(model: model)

    try model.userRequestedRescan()
    presenter.requestIfPending(model: model)
    presenter.environmentDidChange()

    XCTAssertEqual(driver.presentCallCount, 1)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
    XCTAssertTrue(model.isProfileAccessSurfaceActive)
    XCTAssertTrue(model.hasUnresolvedAutomaticProfileAccess)
  }

  func testIncomingURLsFlushInOrderOnceAfterSkipRestoresWindows() throws {
    var lifecycleEvents: [String] = []
    let routing = ProfileAccessRoutingSpy(
      onAccept: { lifecycleEvents.append("accept:\($0.absoluteString)") }
    )
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    driver.onDismissAndRestore = { lifecycleEvents.append("restore") }
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending(routing: routing)
    let delegate = AppDelegate(
      model: model,
      profileAccessPresenter: presenter,
      openSettings: {}
    )
    presenter.requestIfPending(model: model)
    let urls = [
      URL(string: "https://example.com/first")!,
      URL(string: "https://example.com/second")!,
      URL(string: "http://example.com/third")!,
    ]

    delegate.application(NSApplication.shared, open: urls)
    model.skipProfileAccess()

    XCTAssertTrue(routing.acceptedURLs.isEmpty)
    XCTAssertTrue(model.isProfileAccessSurfaceActive)

    presenter.dismiss()

    XCTAssertEqual(routing.acceptedURLs, urls)
    XCTAssertEqual(
      lifecycleEvents,
      ["restore"] + urls.map { "accept:\($0.absoluteString)" }
    )
    XCTAssertFalse(model.isProfileAccessSurfaceActive)

    presenter.dismiss()
    model.profileAccessDidDismiss()
    XCTAssertEqual(routing.acceptedURLs, urls)
  }

  func testIncomingURLFlushesAfterWindowCloseDismissal() throws {
    let routing = ProfileAccessRoutingSpy()
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending(routing: routing)
    let delegate = AppDelegate(
      model: model,
      profileAccessPresenter: presenter,
      openSettings: {}
    )
    presenter.requestIfPending(model: model)
    let url = URL(string: "https://example.com/after-close")!

    delegate.application(NSApplication.shared, open: [url])
    XCTAssertTrue(routing.acceptedURLs.isEmpty)

    driver.closePresentedPanel()

    XCTAssertEqual(model.profileAccessPresentation, .suppressedForProcess)
    XCTAssertFalse(model.isProfileAccessSurfaceActive)
    XCTAssertEqual(routing.acceptedURLs, [url])
  }

  func testIncomingURLFlushesAfterSuccessfulFinishDismissal() throws {
    let routing = ProfileAccessRoutingSpy()
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending(routing: routing)
    let delegate = AppDelegate(
      model: model,
      profileAccessPresenter: presenter,
      openSettings: {}
    )
    presenter.requestIfPending(model: model)
    let url = URL(string: "https://example.com/after-finish")!

    delegate.application(NSApplication.shared, open: [url])
    try model.finishProfileAccessAndRescan()

    XCTAssertTrue(routing.acceptedURLs.isEmpty)
    XCTAssertTrue(model.isProfileAccessSurfaceActive)

    presenter.dismiss()

    XCTAssertEqual(model.profileAccessPresentation, .idle)
    XCTAssertFalse(model.isProfileAccessSurfaceActive)
    XCTAssertEqual(routing.acceptedURLs, [url])
  }

  func testSuppressedProcessDoesNotAutomaticallyRequestAgain() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending()
    presenter.requestIfPending(model: model)
    model.skipProfileAccess()
    presenter.dismiss()

    presenter.requestIfPending(model: model)
    presenter.environmentDidChange()

    XCTAssertEqual(driver.presentCallCount, 1)
    XCTAssertEqual(driver.hideCompetingWindowsCallCount, 1)
  }

  func testQueuedRequestDoesNotPresentAfterProcessBecomesSuppressed() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: false)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending()
    presenter.requestIfPending(model: model)
    model.closeProfileAccess()

    driver.canPresent = true
    presenter.environmentDidChange()

    XCTAssertEqual(driver.presentCallCount, 0)
    XCTAssertEqual(driver.hideCompetingWindowsCallCount, 0)
  }

  func testExplicitRequestPresentsManualManagerAfterAutomaticSuppression() throws {
    let driver = ProfileAccessPanelDriverSpy(canPresent: true)
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = try ProfileAccessModelFixture.automaticPending()
    model.skipProfileAccess()
    model.openProfileAccessManager()

    presenter.request(model: model)

    XCTAssertEqual(driver.presentCallCount, 1)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
  }
}

@MainActor
private final class ProfileAccessPanelDriverSpy: ProfileAccessPanelDriving {
  var environmentDidChangeHandler: (@MainActor () -> Void)?
  var canPresent: Bool {
    get { canPresentProvider?() ?? storedCanPresent }
    set { storedCanPresent = newValue }
  }
  private var storedCanPresent: Bool
  private let canPresentProvider: (@MainActor () -> Bool)?
  private(set) var presentCallCount = 0
  private(set) var hideCompetingWindowsCallCount = 0
  private(set) var dismissAndRestoreWindowsCallCount = 0
  var onDismissAndRestore: (@MainActor () -> Void)?
  private var onClose: (@MainActor () -> Void)?

  init(canPresent: Bool) {
    storedCanPresent = canPresent
    canPresentProvider = nil
  }

  init(canPresent: @escaping @MainActor () -> Bool) {
    storedCanPresent = false
    canPresentProvider = canPresent
  }

  func hideCompetingPickViaWindows() {
    hideCompetingWindowsCallCount += 1
  }

  func present(model: AppModel, onClose: @escaping @MainActor () -> Void) {
    presentCallCount += 1
    self.onClose = onClose
  }

  func dismissAndRestoreWindows() {
    dismissAndRestoreWindowsCallCount += 1
    onDismissAndRestore?()
    onClose = nil
  }

  func closePresentedPanel() {
    onClose?()
  }

  func signalEnvironmentDidChange() {
    environmentDidChangeHandler?()
  }
}

@MainActor
private final class ProfileAccessLifecycleRelay {
  var handler: (@MainActor () -> Void)?
}

@MainActor
private final class PresentationFolderSelectorSpy: ProfileAccessFolderSelecting {
  private(set) var selectCallCount = 0
  private(set) var cancelCallCount = 0
  private var continuation: CheckedContinuation<URL?, Never>?

  func selectRoot(for descriptor: BrowserDescriptor) async -> URL? {
    selectCallCount += 1
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func cancelSelection() {
    cancelCallCount += 1
  }

  func waitUntilSelectionBegins() async {
    while selectCallCount == 0 {
      await Task.yield()
    }
  }

  func resolveSelection(with result: URL?) {
    let pendingContinuation = continuation
    continuation = nil
    pendingContinuation?.resume(returning: result)
  }
}

@MainActor
private enum ProfileAccessModelFixture {
  static func automaticPending(
    onboardingStep: Int = 3,
    routing: any AppRouting = ProfileAccessRoutingStub()
  ) throws -> AppModel {
    let browser = BrowserApplication(
      id: "com.google.Chrome",
      family: .chromium,
      displayName: "Google Chrome",
      bundleIdentifier: "com.google.Chrome",
      applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
      executableURL: nil,
      isAvailable: true
    )
    let scan = BrowserScanResult(
      browsers: [
        DiscoveredBrowser(
          application: browser,
          profiles: [],
          metadataStatus: .accessRequired
        )
      ],
      profileAccessIssues: [.accessRequired(bundleIdentifier: browser.bundleIdentifier)]
    )
    let model = AppModel(
      configStore: ProfileAccessConfigStoreStub(),
      browserCatalog: ProfileAccessCatalogStub(result: scan),
      preferences: ProfileAccessPreferencesStub(onboardingStep: onboardingStep),
      defaultBrowser: ProfileAccessDefaultBrowserStub(),
      loginItem: ProfileAccessLoginItemStub(),
      routing: routing
    )
    try model.load()
    return model
  }
}

private struct ProfileAccessConfigStoreStub: ConfigStoring {
  func load() throws -> PickViaConfig { .initial }
  func save(_ config: PickViaConfig) throws {}
}

private struct ProfileAccessCatalogStub: BrowserDiscovering {
  let result: BrowserScanResult

  func scan() throws -> [DiscoveredBrowser] { result.browsers }
  func scanResult() -> BrowserScanResult { result }
  func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig {
    config
  }
}

@MainActor
private final class ProfileAccessPreferencesStub: PreferencesStoring {
  private let onboardingStep: Int

  init(onboardingStep: Int) {
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
private final class ProfileAccessDefaultBrowserStub: DefaultBrowserServicing {
  func status() -> DefaultBrowserStatus { .unknown }
  func requestDefault(for schemes: [String]) async throws {}
}

@MainActor
private final class ProfileAccessLoginItemStub: LoginItemServicing {
  var isEnabled: Bool { false }
  func setEnabled(_ enabled: Bool) throws {}
}

@MainActor
private final class ProfileAccessRoutingStub: AppRouting {
  func accept(_ url: URL) {}
  func preview(_ url: URL) {}
}

@MainActor
private final class ProfileAccessRoutingSpy: AppRouting {
  private(set) var acceptedURLs: [URL] = []
  private let onAccept: @MainActor (URL) -> Void

  init(onAccept: @escaping @MainActor (URL) -> Void = { _ in }) {
    self.onAccept = onAccept
  }

  func accept(_ url: URL) {
    acceptedURLs.append(url)
    onAccept(url)
  }

  func preview(_ url: URL) {}
}
