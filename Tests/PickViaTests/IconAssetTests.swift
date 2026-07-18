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
