import AppKit
import XCTest
@testable import PickVia

final class ChooserPanelLayoutTests: XCTestCase {
  private let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
  private let panel = CGSize(width: 360, height: 300)

  func testContentWidthAndMaximumHeightUseApprovedConstants() {
    XCTAssertEqual(ChooserPanelLayout.contentWidth, 360)
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
}
