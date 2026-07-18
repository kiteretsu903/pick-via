import Foundation
import XCTest

final class BrowserSettingsViewTests: XCTestCase {
  func testBrowserSettingsUsesStableLabeledActionsOutsideNativeToolbar() throws {
    let source = try projectSource("Sources/PickVia/Views/BrowserSettingsView.swift")

    XCTAssertTrue(source.contains("Label(\"Add Target\", systemImage: \"plus\")"))
    XCTAssertTrue(source.contains("Label(\"Profile Access\", systemImage: \"folder.badge.key\")"))
    XCTAssertTrue(source.contains("Label(\"Rescan\", systemImage: \"arrow.clockwise\")"))
    XCTAssertTrue(source.contains(".labelStyle(.titleAndIcon)"))
    XCTAssertFalse(source.contains("ToolbarItemGroup"))
  }

  func testProfileAccessActionRemainsStable() throws {
    let source = try projectSource("Sources/PickVia/Views/BrowserSettingsView.swift")

    XCTAssertTrue(source.contains("model.openProfileAccessManager()"))
    XCTAssertTrue(source.contains("profileAccessPresenter.request(model: model)"))
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
