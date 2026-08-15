import Foundation
import PickViaCore
import XCTest

@testable import PickVia

final class MailSettingsViewTests: XCTestCase {
  func testMailDestinationUsesEnvelopeIcon() {
    XCTAssertEqual(SettingsDestination.mail.title, "Mail")
    XCTAssertEqual(SettingsDestination.mail.systemImage, "envelope")
  }

  func testMailRowsPreserveConfiguredOrderAndAvailability() {
    let rows = makeMailSettingsRows(
      applications: [Fixtures.outlookMissing, Fixtures.appleMail],
      targets: [Fixtures.outlookTarget(order: 0), Fixtures.appleMailTarget(order: 1)]
    )

    XCTAssertEqual(
      rows.map(\.targetID),
      [
        Fixtures.outlookTargetID,
        Fixtures.appleMailTargetID,
      ])
    XCTAssertEqual(rows.map(\.isAvailable), [false, true])
  }
}

private enum Fixtures {
  static let outlookTargetID = "mailto|com.microsoft.Outlook"
  static let appleMailTargetID = "mailto|com.apple.mail"

  static let appleMail = RoutedApplication(
    id: "com.apple.mail",
    displayName: "Mail",
    bundleIdentifier: "com.apple.mail",
    capabilities: [.mail(isAvailable: true)],
    applicationURL: URL(fileURLWithPath: "/System/Applications/Mail.app")
  )

  static let outlookMissing = RoutedApplication(
    id: "com.microsoft.Outlook",
    displayName: "Microsoft Outlook",
    bundleIdentifier: "com.microsoft.Outlook",
    capabilities: [.mail(isAvailable: false)],
    applicationURL: URL(fileURLWithPath: "/Applications/Microsoft Outlook.app")
  )

  static func appleMailTarget(order: Int) -> RouteTarget {
    RouteTarget(
      id: appleMailTargetID,
      applicationID: appleMail.id,
      label: appleMail.displayName,
      isEnabled: true,
      sortOrder: order,
      origin: .detected,
      availability: .available,
      capability: .mail
    )
  }

  static func outlookTarget(order: Int) -> RouteTarget {
    RouteTarget(
      id: outlookTargetID,
      applicationID: outlookMissing.id,
      label: outlookMissing.displayName,
      isEnabled: true,
      sortOrder: order,
      origin: .detected,
      availability: .available,
      capability: .mail
    )
  }
}
