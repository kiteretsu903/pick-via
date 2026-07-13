import AppKit
import Foundation
import PickViaCore
import SwiftUI
import XCTest

@testable import PickVia

@MainActor
final class ProfileAccessPresentationTests: XCTestCase {
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
private enum ProfileAccessModelFixture {
  static func automaticPending(onboardingStep: Int = 3) throws -> AppModel {
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
      routing: ProfileAccessRoutingStub()
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
