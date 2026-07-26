import Foundation
import XCTest

@testable import PickViaCore

final class RouteModelTests: XCTestCase {
  func testApplicationCanSupportWebAndMailWithoutDuplicateIdentity() throws {
    let application = RoutedApplication(
      id: "com.example.Client",
      displayName: "Client",
      bundleIdentifier: "com.example.Client",
      capabilities: [
        .browser(family: .chromium, isAvailable: true),
        .mail(isAvailable: true),
      ],
      applicationURL: URL(fileURLWithPath: "/Applications/Client.app")
    )

    XCTAssertTrue(application.supports(.web))
    XCTAssertTrue(application.supports(.mail))
    XCTAssertEqual(application.browserFamily, .chromium)
    XCTAssertTrue(application.isAvailable(for: .web))
    XCTAssertTrue(application.isAvailable(for: .mail))
  }

  func testVersionTwoBrowserDocumentMigratesWithoutChangingTargetIdentity() throws {
    let data = Data(versionTwoChromeDocument.utf8)
    let decoded = try JSONDecoder().decode(PickViaConfig.self, from: data)
      .validatedAndMigrated()

    XCTAssertEqual(decoded.schemaVersion, 3)
    XCTAssertEqual(decoded.applications.count, 1)
    XCTAssertEqual(decoded.applications.map(\.id), ["com.google.Chrome"])
    XCTAssertEqual(decoded.applications[0].displayName, "Google Chrome")
    XCTAssertEqual(decoded.applications[0].bundleIdentifier, "com.google.Chrome")
    XCTAssertEqual(
      decoded.applications[0].capabilities,
      [.browser(family: .chromium, isAvailable: false)]
    )
    XCTAssertEqual(decoded.applications[0].browserFamily, .chromium)
    XCTAssertEqual(
      decoded.applications[0].applicationURL,
      URL(fileURLWithPath: "/", isDirectory: true)
    )
    XCTAssertNil(decoded.applications[0].browserExecutableURL)

    XCTAssertEqual(decoded.targets.count, 1)
    XCTAssertEqual(decoded.targets.map(\.id), ["com.google.Chrome|Profile 1|normal"])
    XCTAssertEqual(decoded.targets[0].applicationID, "com.google.Chrome")
    XCTAssertEqual(decoded.targets[0].label, "Work")
    XCTAssertTrue(decoded.targets[0].isEnabled)
    XCTAssertEqual(decoded.targets[0].sortOrder, 7)
    XCTAssertEqual(decoded.targets[0].origin, .detected)
    XCTAssertEqual(decoded.targets[0].availability, .unavailable)
    XCTAssertEqual(decoded.targets[0].routeKind, .web)
    XCTAssertEqual(decoded.targets[0].browserOptions?.profileIdentifier, "Profile 1")
    XCTAssertEqual(decoded.targets[0].browserOptions?.profileDisplayName, "Work")
    XCTAssertEqual(decoded.targets[0].browserOptions?.profileIdentity, "Profile 1")
    XCTAssertNil(decoded.targets[0].browserOptions?.profileLaunchPath)
    XCTAssertEqual(decoded.targets[0].browserOptions?.mode, .normal)
    XCTAssertEqual(decoded.targets[0].browserOptions?.pendingDefaultMigration, false)
    XCTAssertEqual(decoded.targets[0].browserOptions?.validationError, "Needs rescan")
  }

  func testSchemaThreeValidationIsIdempotent() throws {
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [Fixtures.chromeApplication],
      targets: []
    )

    let first = try config.validatedAndMigrated()
    let second = try first.validatedAndMigrated()

    XCTAssertEqual(first, config)
    XCTAssertEqual(second, first)
  }

  func testMailTargetRejectsApplicationWithoutMailCapability() {
    let config = PickViaConfig(
      schemaVersion: 3,
      applications: [Fixtures.chromeApplication],
      targets: [Fixtures.mailTarget(applicationID: Fixtures.chromeApplication.id)]
    )

    XCTAssertThrowsError(try config.validatedAndMigrated())
  }

  func testMailApplicationCapabilityRejectsBrowserOnlyFamilyPayload() {
    let data = Data(
      """
      {
        "kind": "mail",
        "family": "chromium",
        "isAvailable": true
      }
      """.utf8
    )

    XCTAssertThrowsError(try JSONDecoder().decode(ApplicationCapability.self, from: data))
  }

  func testMailTargetCapabilityRejectsBrowserOptionsPayload() {
    let data = Data(
      """
      {
        "kind": "mail",
        "browserOptions": {
          "mode": "normal"
        }
      }
      """.utf8
    )

    XCTAssertThrowsError(try JSONDecoder().decode(RouteTargetCapability.self, from: data))
  }

  private let versionTwoChromeDocument = """
    {
      "schemaVersion": 2,
      "browsers": [
        {
          "id": "com.google.Chrome",
          "family": "chromium",
          "displayName": "Google Chrome",
          "bundleIdentifier": "com.google.Chrome",
          "isAvailable": false
        }
      ],
      "targets": [
        {
          "id": "com.google.Chrome|Profile 1|normal",
          "browserID": "com.google.Chrome",
          "label": "Work",
          "profileIdentifier": "Profile 1",
          "profileDisplayName": "Work",
          "profileIdentity": "Profile 1",
          "mode": "normal",
          "isEnabled": true,
          "sortOrder": 7,
          "origin": "detected",
          "availability": "unavailable",
          "pendingDefaultMigration": false,
          "validationError": "Needs rescan"
        }
      ]
    }
    """
}

private enum Fixtures {
  static let chromeApplication = RoutedApplication(
    id: "com.google.Chrome",
    displayName: "Google Chrome",
    bundleIdentifier: "com.google.Chrome",
    capabilities: [.browser(family: .chromium, isAvailable: true)],
    applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
    browserExecutableURL: URL(
      fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
  )

  static func mailTarget(applicationID: RoutedApplication.ID) -> RouteTarget {
    RouteTarget(
      id: RouteTarget.mailID(bundleIdentifier: applicationID),
      applicationID: applicationID,
      label: "Mail",
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available,
      capability: .mail
    )
  }
}
