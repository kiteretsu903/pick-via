import XCTest

@testable import PickVia

@MainActor
final class SettingsSceneOpenerTests: XCTestCase {
  func testPendingOpenIsReplayedWhenSwiftUIActionIsInstalled() {
    let opener = SettingsSceneOpener()
    var openCount = 0

    opener.open()
    opener.install { openCount += 1 }

    XCTAssertEqual(openCount, 1)
  }

  func testMultiplePendingRequestsCoalesceIntoOneWindowOpen() {
    let opener = SettingsSceneOpener()
    var openCount = 0

    opener.open()
    opener.open()
    opener.install { openCount += 1 }

    XCTAssertEqual(openCount, 1)
  }

  func testInstalledSwiftUIActionHandlesSubsequentRequests() {
    let opener = SettingsSceneOpener()
    var openCount = 0
    opener.install { openCount += 1 }

    opener.open()
    opener.open()

    XCTAssertEqual(openCount, 2)
  }
}
