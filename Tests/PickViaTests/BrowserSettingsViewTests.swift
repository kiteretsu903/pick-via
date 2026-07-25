import Foundation
import XCTest

final class BrowserSettingsViewTests: XCTestCase {
  func testGeneralSettingsContainsSegmentedChooserSizePicker() throws {
    let source = try projectSource("Sources/PickVia/Views/GeneralSettingsView.swift")

    XCTAssertTrue(source.contains("Picker(\"Chooser size\""))
    XCTAssertTrue(source.contains("ChooserDensity.allCases"))
    XCTAssertTrue(source.contains(".pickerStyle(.segmented)"))
  }

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

  func testChooserUsesAdaptiveTargetScrollingAndDensityWidth() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserView.swift")

    XCTAssertTrue(source.contains("ViewThatFits(in: .vertical)"))
    XCTAssertTrue(source.contains("ScrollViewReader"))
    XCTAssertTrue(source.contains("scrollTo(selectedTargetID"))
    XCTAssertTrue(source.contains(".frame(width: density.metrics.contentWidth)"))
    XCTAssertTrue(source.contains(".lineLimit(1)"))
  }

  func testChooserRowsAreSingleLineAndDoNotRenderDetailText() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserView.swift")
    XCTAssertFalse(source.contains("detail(for:"))
    XCTAssertTrue(source.contains("ChooserTargetRow("))

    let rowSource = try projectSource("Sources/PickVia/Chooser/ChooserTargetRow.swift")
    XCTAssertTrue(rowSource.contains("Text(label)"))
    XCTAssertTrue(rowSource.contains(".lineLimit(1)"))
    XCTAssertTrue(rowSource.contains(".truncationMode(.tail)"))
    XCTAssertFalse(rowSource.contains("VStack"))
  }

  func testChooserSelectionUsesTintAndInsetBorderWithoutShadow() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserTargetRow.swift")
    let fillStart = try XCTUnwrap(source.range(of: "private var selectionFill: Color"))
    let fillEnd = try XCTUnwrap(
      source.range(of: "private func applicationIcon", range: fillStart.upperBound..<source.endIndex)
    )
    let fill = String(source[fillStart.lowerBound..<fillEnd.lowerBound])
    let selected = try XCTUnwrap(
      fill.range(of: "if isSelected { return Color.accentColor.opacity(0.16) }")
    )
    let hover = try XCTUnwrap(
      fill.range(of: "if isHovering { return Color.accentColor.opacity(0.07) }")
    )

    XCTAssertLessThan(selected.lowerBound, hover.lowerBound)
    XCTAssertTrue(source.contains("isSelected ? Color.accentColor.opacity(0.55) : .clear"))
    XCTAssertTrue(source.contains(".strokeBorder"))
    XCTAssertTrue(source.contains(".onHover { isHovering = $0 }"))
    XCTAssertFalse(source.contains(".shadow"))
  }

  func testChooserRowsDisableNativeFocusEffect() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserTargetRow.swift")

    XCTAssertTrue(source.contains(".buttonStyle(.plain)\n    .focusEffectDisabled()"))
  }

  func testChooserUsesStandardWindowCornerRadius() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserView.swift")

    XCTAssertTrue(
      source.contains(
        ".clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))"
      )
    )
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
