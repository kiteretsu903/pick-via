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
    let delegate = AppDelegate(
      model: model,
      navigation: navigation,
      openSettings: { destinationWhenOpened = navigation.destination }
    )

    delegate.applicationDidFinishLaunching(
      Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    XCTAssertEqual(destinationWhenOpened, .browsers)
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

  private func makeModel(
    routing: AppDelegateRoutingSpy = AppDelegateRoutingSpy(),
    defaultBrowser: AppDelegateDefaultBrowserStub = AppDelegateDefaultBrowserStub()
  ) -> AppModel {
    AppModel(
      configStore: AppDelegateConfigStoreStub(),
      browserCatalog: AppDelegateCatalogStub(),
      preferences: AppDelegatePreferencesStub(),
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
  func scan() throws -> [DiscoveredBrowser] { [] }
  func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig {
    config
  }
}

@MainActor
private final class AppDelegatePreferencesStub: PreferencesStoring {
  func bool(forKey key: String) -> Bool? { nil }
  func integer(forKey key: String) -> Int? { nil }
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
