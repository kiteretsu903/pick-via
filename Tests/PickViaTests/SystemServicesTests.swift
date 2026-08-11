import Foundation
import XCTest

@testable import PickVia

@MainActor
final class DefaultBrowserServiceTests: XCTestCase {
  func testSameBundleIdentifierIsDefaultWhenRegisteredPathDiffers() {
    let runningApplication = URL(fileURLWithPath: "/current/PickVia.app")
    let registeredHandler = URL(fileURLWithPath: "/old-build/PickVia.app")

    let status = MacOSDefaultBrowserService.status(
      handlerURL: registeredHandler,
      applicationURL: runningApplication,
      bundleIdentifierForURL: { _ in "dev.bozhenpeng.PickVia" }
    )

    XCTAssertEqual(status, .isDefault)
  }

  func testExactPathIsDefaultWhenBundleMetadataIsUnavailable() {
    let application = URL(fileURLWithPath: "/Applications/PickVia.app")

    let status = MacOSDefaultBrowserService.status(
      handlerURL: application,
      applicationURL: application,
      bundleIdentifierForURL: { _ in nil }
    )

    XCTAssertEqual(status, .isDefault)
  }
}
