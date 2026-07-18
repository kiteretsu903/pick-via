import Foundation
import XCTest

final class BrowserSettingsViewTests: XCTestCase {
  func testFixedActionStripContainsStableLabeledActionsAndProfileAccessFlow() throws {
    let source = try projectSource("Sources/PickVia/Views/BrowserSettingsView.swift")
    let strip = try fixedActionStrip(in: source)

    XCTAssertTrue(strip.contains("VStack(spacing: 0)"))
    XCTAssertTrue(strip.contains("Label(\"Add Target\", systemImage: \"plus\")"))
    XCTAssertTrue(strip.contains("Label(\"Profile Access\", systemImage: \"folder.badge.key\")"))
    XCTAssertTrue(strip.contains("Label(\"Rescan\", systemImage: \"arrow.clockwise\")"))
    XCTAssertTrue(strip.contains(".labelStyle(.titleAndIcon)"))
    XCTAssertTrue(strip.contains("model.openProfileAccessManager()"))
    XCTAssertTrue(strip.contains("profileAccessPresenter.request(model: model)"))
  }

  func testBrowserSettingsRejectsAnyNativeToolbarPlacement() throws {
    let source = try projectSource("Sources/PickVia/Views/BrowserSettingsView.swift")

    XCTAssertFalse(source.contains(".toolbar"))
    XCTAssertFalse(source.contains("ToolbarItem"))
  }

  func testChooserUsesAdaptiveTargetScrollingAndCompactWidth() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserView.swift")

    XCTAssertTrue(source.contains("ViewThatFits(in: .vertical)"))
    XCTAssertTrue(source.contains("ScrollViewReader"))
    XCTAssertTrue(source.contains("scrollTo(selectedTargetID"))
    XCTAssertTrue(source.contains("ChooserPanelLayout.contentWidth"))
    XCTAssertTrue(source.contains(".lineLimit(1)"))
  }

  func testChooserTargetLabelAndDetailUseOneLineTailTruncation() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserView.swift")
    let rowStart = try XCTUnwrap(source.range(of: "private func rowView"))
    let rowEnd = try XCTUnwrap(
      source.range(of: "private func applicationIcon", range: rowStart.upperBound..<source.endIndex)
    )
    let row = String(source[rowStart.lowerBound..<rowEnd.lowerBound])
    let labelStart = try XCTUnwrap(row.range(of: "Text(target.label)"))
    let detailStart = try XCTUnwrap(
      row.range(of: "Text(detail(for:", range: labelStart.upperBound..<row.endIndex)
    )
    let spacer = try XCTUnwrap(
      row.range(of: "Spacer()", range: detailStart.upperBound..<row.endIndex)
    )
    let label = String(row[labelStart.lowerBound..<detailStart.lowerBound])
    let detail = String(row[detailStart.lowerBound..<spacer.lowerBound])

    XCTAssertTrue(label.contains(".lineLimit(1)"))
    XCTAssertTrue(label.contains(".truncationMode(.tail)"))
    XCTAssertTrue(detail.contains(".lineLimit(1)"))
    XCTAssertTrue(detail.contains(".truncationMode(.tail)"))
  }

  private func fixedActionStrip(in source: String) throws -> String {
    let body = try XCTUnwrap(source.range(of: "public var body: some View {"))
    let dividerAndList = try XCTUnwrap(
      source.range(
        of: "\n      Divider()\n\n      List {",
        range: body.upperBound..<source.endIndex
      )
    )
    return String(source[body.upperBound..<dividerAndList.lowerBound])
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
