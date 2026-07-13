import AppKit
import Foundation
import PickViaCore
import XCTest

@testable import PickVia

@MainActor
final class AppDelegateTests: XCTestCase {
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
    let delegate = AppDelegate(model: makeModel(), openSettings: { openSettingsCallCount += 1 })

    let handled = delegate.applicationShouldHandleReopen(
      NSApplication.shared,
      hasVisibleWindows: false
    )

    XCTAssertTrue(handled)
    XCTAssertEqual(openSettingsCallCount, 1)
  }

  private func makeModel(routing: AppDelegateRoutingSpy = AppDelegateRoutingSpy()) -> AppModel {
    AppModel(
      configStore: AppDelegateConfigStoreStub(),
      browserCatalog: AppDelegateCatalogStub(),
      preferences: AppDelegatePreferencesStub(),
      defaultBrowser: AppDelegateDefaultBrowserStub(),
      loginItem: AppDelegateLoginItemStub(),
      routing: routing
    )
  }
}

private struct AppDelegateConfigStoreStub: ConfigStoring {
  func load() throws -> PickViaConfig { .initial }
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
  func status() -> DefaultBrowserStatus { .unknown }
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
