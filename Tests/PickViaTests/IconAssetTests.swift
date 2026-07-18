import AppKit
import XCTest

final class IconAssetTests: XCTestCase {
  func testApplicationIconContainsRequiredPixelRepresentations() throws {
    let image = try XCTUnwrap(NSImage(contentsOf: assetURL("PickVia.icns")))
    let widths = Set(image.representations.map(\.pixelsWide))

    XCTAssertTrue([16, 32, 64, 128, 256, 512, 1024].allSatisfy(widths.contains))
  }

  func testMenuTemplateIsTransparentTwoTimesArtwork() throws {
    let data = try Data(contentsOf: assetURL("PickViaMenuBarTemplate.png"))
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))

    XCTAssertEqual(bitmap.pixelsWide, 44)
    XCTAssertEqual(bitmap.pixelsHigh, 44)
    XCTAssertTrue(bitmap.hasAlpha)
    XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0, accuracy: 0.01)
  }

  func testGeneratorContainsApprovedPaletteAndNativeToolingOnly() throws {
    let source = try String(contentsOf: repositoryRoot.appending(path: "scripts/generate-icons.swift"))

    XCTAssertTrue(source.contains("0x8177F2"))
    XCTAssertTrue(source.contains("0x545DD3"))
    XCTAssertTrue(source.contains("0x30387F"))
    XCTAssertTrue(source.contains("/usr/bin/iconutil"))
    XCTAssertFalse(source.contains("http://"))
    XCTAssertFalse(source.contains("https://"))
  }

  func testGeneratorValidatesBothStagedAssetsBeforeReplacingOutputs() throws {
    let source = try String(contentsOf: repositoryRoot.appending(path: "scripts/generate-icons.swift"))
    let menuValidation = try XCTUnwrap(source.range(of: "try validateMenuTemplate(at: stagedMenu)"))
    let iconValidation = try XCTUnwrap(source.range(of: "try validateApplicationIcon(at: stagedICNS)"))
    let outputReplacement = try XCTUnwrap(
      source.range(of: "try FileManager.default.createDirectory(at: outputDirectory")
    )

    XCTAssertLessThan(menuValidation.lowerBound, outputReplacement.lowerBound)
    XCTAssertLessThan(iconValidation.lowerBound, outputReplacement.lowerBound)
  }

  func testGeneratorReproducesBothValidatedAssetsInAlternateOutputDirectory() throws {
    let outputDirectory = FileManager.default.temporaryDirectory
      .appending(path: "pickvia-icon-asset-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: outputDirectory) }

    let generator = Process()
    generator.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    generator.arguments = [
      "swift",
      repositoryRoot.appending(path: "scripts/generate-icons.swift").path,
      "--output-dir",
      outputDirectory.path,
    ]
    try generator.run()
    generator.waitUntilExit()

    XCTAssertEqual(generator.terminationStatus, 0)
    XCTAssertEqual(
      try Data(contentsOf: outputDirectory.appending(path: "PickVia.icns")),
      try Data(contentsOf: assetURL("PickVia.icns"))
    )
    XCTAssertEqual(
      try Data(contentsOf: outputDirectory.appending(path: "PickViaMenuBarTemplate.png")),
      try Data(contentsOf: assetURL("PickViaMenuBarTemplate.png"))
    )
  }

  private func assetURL(_ name: String) -> URL {
    repositoryRoot.appending(path: "Support/Icons/\(name)")
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
