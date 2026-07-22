import AppKit
import XCTest

@testable import PickVia

final class ChooserPanelLayoutTests: XCTestCase {
  private let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
  private let panel = CGSize(width: 360, height: 300)

  func testMaximumHeightUsesApprovedConstants() {
    XCTAssertEqual(ChooserPanelLayout.maximumPanelHeight(in: visible), 776)
  }

  func testPlacesBelowRightWhenThereIsRoom() {
    XCTAssertEqual(
      ChooserPanelLayout.origin(
        pointer: CGPoint(x: 200, y: 600), panelSize: panel, visibleFrame: visible),
      CGPoint(x: 210, y: 290)
    )
  }

  func testFlipsLeftAtRightEdge() {
    XCTAssertEqual(
      ChooserPanelLayout.origin(
        pointer: CGPoint(x: 900, y: 600), panelSize: panel, visibleFrame: visible),
      CGPoint(x: 530, y: 290)
    )
  }

  func testFlipsAboveAtBottomEdge() {
    XCTAssertEqual(
      ChooserPanelLayout.origin(
        pointer: CGPoint(x: 200, y: 100), panelSize: panel, visibleFrame: visible),
      CGPoint(x: 210, y: 110)
    )
  }

  func testFlipsBothAndClampsInsideVisibleFrame() {
    XCTAssertEqual(
      ChooserPanelLayout.origin(
        pointer: CGPoint(x: 995, y: 5), panelSize: panel, visibleFrame: visible),
      CGPoint(x: 625, y: 15)
    )
  }

  func testUsesAbsoluteCoordinatesForNonzeroScreenOrigin() {
    let offsetVisibleFrame = CGRect(x: 1440, y: -200, width: 1200, height: 900)

    XCTAssertEqual(
      ChooserPanelLayout.origin(
        pointer: CGPoint(x: 1600, y: 500),
        panelSize: panel,
        visibleFrame: offsetVisibleFrame
      ),
      CGPoint(x: 1610, y: 190)
    )
  }

  func testOversizedPanelClampsToAvailableScreenMargins() {
    let smallVisibleFrame = CGRect(x: 100, y: 200, width: 300, height: 220)

    XCTAssertEqual(
      ChooserPanelLayout.origin(
        pointer: CGPoint(x: 250, y: 310),
        panelSize: CGSize(width: 360, height: 300),
        visibleFrame: smallVisibleFrame
      ),
      CGPoint(x: 112, y: 212)
    )
  }

  func testPointerOutsideEveryScreenChoosesCenteredFallback() {
    let screens = [
      CGRect(x: 0, y: 0, width: 1000, height: 800),
      CGRect(x: 1000, y: -200, width: 1200, height: 900),
    ]

    XCTAssertEqual(
      ChooserPanelLayout.placement(
        pointer: CGPoint(x: -500, y: 2000),
        screenFrames: screens
      ),
      .centered
    )
    XCTAssertEqual(
      ChooserPanelLayout.placement(
        pointer: CGPoint(x: 1500, y: 200),
        screenFrames: screens
      ),
      .pointerAnchored(screenIndex: 1)
    )
  }

  func testCenteredOriginUsesMainVisibleFrameAbsoluteCoordinates() {
    XCTAssertEqual(
      ChooserPanelLayout.centeredOrigin(
        panelSize: panel,
        visibleFrame: CGRect(x: 1440, y: -200, width: 1200, height: 900)
      ),
      CGPoint(x: 1860, y: 100)
    )
  }

  func testControllerFallbackUsesExplicitMainScreenOriginInsteadOfWindowCenter() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserPanelController.swift")

    XCTAssertTrue(source.contains("let mainVisibleFrame = NSScreen.main?.visibleFrame"))
    XCTAssertTrue(source.contains("ChooserPanelLayout.centeredOrigin"))
    XCTAssertTrue(source.contains("panel.setFrameOrigin"))
    XCTAssertFalse(source.contains("panel.center()"))
  }

  private func projectSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repositoryRoot.appending(path: relativePath),
      encoding: .utf8
    )
  }
}
