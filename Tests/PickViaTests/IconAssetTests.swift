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

  func testMenuTemplateArtworkIsCenteredWithTransparentOuterEdges() throws {
    let data = try Data(contentsOf: assetURL("PickViaMenuBarTemplate.png"))
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
    var nonTransparentPixels: [(x: Int, y: Int)] = []

    for y in 0..<bitmap.pixelsHigh {
      for x in 0..<bitmap.pixelsWide {
        if try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent > 0 {
          nonTransparentPixels.append((x, y))
        }
      }
    }

    let minX = try XCTUnwrap(nonTransparentPixels.map(\.x).min())
    let maxX = try XCTUnwrap(nonTransparentPixels.map(\.x).max())
    let minY = try XCTUnwrap(nonTransparentPixels.map(\.y).min())
    let maxY = try XCTUnwrap(nonTransparentPixels.map(\.y).max())

    XCTAssertEqual(minX, bitmap.pixelsWide - 1 - maxX)
    XCTAssertEqual(minY, bitmap.pixelsHigh - 1 - maxY)
    XCTAssertGreaterThan(minX, 0)
    XCTAssertLessThan(maxX, bitmap.pixelsWide - 1)
    XCTAssertGreaterThan(minY, 0)
    XCTAssertLessThan(maxY, bitmap.pixelsHigh - 1)
  }

  func testGeneratorUsesCheckedInArtworkAndNativeICNSContainer() throws {
    let source = try String(
      contentsOf: repositoryRoot.appending(path: "scripts/generate-icons.swift"))

    XCTAssertTrue(source.contains("PickViaArtwork.png"))
    XCTAssertTrue(source.contains("ic10"))
    XCTAssertFalse(source.contains("http://"))
    XCTAssertFalse(source.contains("https://"))
  }

  func testApplicationArtworkHasTransparentCornersAndEnoughResolution() throws {
    let data = try Data(contentsOf: assetURL("PickViaArtwork.png"))
    let representation = try XCTUnwrap(
      NSBitmapImageRep(data: data))

    XCTAssertGreaterThanOrEqual(representation.pixelsWide, 1024)
    XCTAssertGreaterThanOrEqual(representation.pixelsHigh, 1024)
    XCTAssertTrue(representation.hasAlpha)
    XCTAssertEqual(
      try XCTUnwrap(representation.colorAt(x: 0, y: 0)).alphaComponent,
      0,
      accuracy: 0.01
    )
  }

  func testGeneratorValidatesBothStagedAssetsBeforeReplacingOutputs() throws {
    let source = try String(
      contentsOf: repositoryRoot.appending(path: "scripts/generate-icons.swift"))
    let menuValidation = try XCTUnwrap(source.range(of: "try validateMenuTemplate(at: stagedMenu)"))
    let iconValidation = try XCTUnwrap(
      source.range(of: "try validateApplicationIcon(at: stagedICNS)"))
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

  func testGeneratorRejectsMalformedArgumentsBeforeGeneratingAssets() throws {
    for arguments in [
      ["--output-dir"],
      ["--output-dir", ""],
      ["--output-dir", "--not-a-path"],
      ["--unexpected"],
      ["--output-dir", FileManager.default.temporaryDirectory.path, "extra"],
    ] {
      let result = try runGenerator(arguments: arguments)

      XCTAssertNotEqual(result.status, 0, "Expected failure for \(arguments)")
      XCTAssertTrue(
        result.output.contains("invalidArguments"),
        "Expected invalid-argument failure for \(arguments), got: \(result.output)"
      )
    }
  }

  private func runGenerator(arguments: [String]) throws -> (status: Int32, output: String) {
    let generator = Process()
    let output = Pipe()
    generator.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    generator.arguments =
      [
        "swift",
        repositoryRoot.appending(path: "scripts/generate-icons.swift").path,
      ] + arguments
    generator.standardOutput = output
    generator.standardError = output
    try generator.run()
    generator.waitUntilExit()

    return (
      generator.terminationStatus,
      String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
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
