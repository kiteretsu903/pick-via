import AppKit
import XCTest

@testable import PickVia

@MainActor
final class AppWindowSpaceCoordinatorTests: XCTestCase {
  func testPrepareMovesVisibleOrdinaryWindowAndPreservesUnrelatedBehavior() {
    let window = makeVisibleWindow()
    window.collectionBehavior = [.managed, .canJoinAllSpaces]

    AppWindowSpaceCoordinator(windowsProvider: { [window] })
      .prepareVisibleWindowsForActivation()

    XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
    XCTAssertTrue(window.collectionBehavior.contains(.managed))
    XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces))
  }

  func testPrepareDoesNotModifyHiddenWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.collectionBehavior = [.canJoinAllSpaces]
    XCTAssertFalse(window.isVisible)

    AppWindowSpaceCoordinator(windowsProvider: { [window] })
      .prepareVisibleWindowsForActivation()

    XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces])
  }

  func testPrepareDoesNotModifyPanel() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    panel.collectionBehavior = [.canJoinAllSpaces]
    panel.orderFrontRegardless()
    XCTAssertTrue(panel.isVisible)

    AppWindowSpaceCoordinator(windowsProvider: { [panel] })
      .prepareVisibleWindowsForActivation()

    XCTAssertEqual(panel.collectionBehavior, [.canJoinAllSpaces])
  }

  func testPrepareDoesNotModifyNonNormalLevelWindow() {
    let window = makeVisibleWindow(level: .floating)
    window.collectionBehavior = [.canJoinAllSpaces]

    AppWindowSpaceCoordinator(windowsProvider: { [window] })
      .prepareVisibleWindowsForActivation()

    XCTAssertEqual(window.collectionBehavior, [.canJoinAllSpaces])
  }

  func testPrepareDoesNotModifySheet() {
    let parent = makeVisibleWindow()
    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    sheet.collectionBehavior = [.canJoinAllSpaces]
    parent.beginSheet(sheet)
    defer {
      parent.endSheet(sheet)
      sheet.orderOut(nil)
      parent.orderOut(nil)
    }
    XCTAssertTrue(sheet.isVisible)
    XCTAssertTrue(sheet.isSheet)

    AppWindowSpaceCoordinator(windowsProvider: { [sheet] })
      .prepareVisibleWindowsForActivation()

    XCTAssertEqual(sheet.collectionBehavior, [.canJoinAllSpaces])
  }

  private func makeVisibleWindow(level: NSWindow.Level = .normal) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.level = level
    window.orderFrontRegardless()
    XCTAssertTrue(window.isVisible)
    return window
  }
}
