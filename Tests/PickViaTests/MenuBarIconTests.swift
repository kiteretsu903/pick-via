import AppKit
import XCTest

@testable import PickVia

final class MenuBarIconTests: XCTestCase {
  func testCheckedInMenuIconLoadsAsTwentyTwoPointTemplate() throws {
    let image = try XCTUnwrap(PickViaMenuBarIcon.load(from: menuAssetURL))

    XCTAssertTrue(image.isTemplate)
    XCTAssertEqual(image.size, NSSize(width: 22, height: 22))
  }

  func testMissingMenuIconUsesStableSystemFallbackName() {
    XCTAssertNil(PickViaMenuBarIcon.load(from: nil))
    XCTAssertEqual(PickViaMenuBarIcon.fallbackSystemName, "arrow.triangle.branch")
  }

  func testAppCompositionUsesCustomMenuBarLabel() throws {
    let source = try String(contentsOf: repositoryRoot.appending(path: "Sources/PickVia/App/PickViaApp.swift"))

    XCTAssertTrue(source.contains("PickViaMenuBarLabel()"))
    XCTAssertFalse(source.contains("MenuBarExtra(\"PickVia\", systemImage:"))
  }

  private var menuAssetURL: URL {
    repositoryRoot.appending(path: "Support/Icons/PickViaMenuBarTemplate.png")
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
