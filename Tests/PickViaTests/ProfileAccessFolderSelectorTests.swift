import Foundation
import PickViaCore
import XCTest

@testable import PickVia

@MainActor
final class ProfileAccessFolderSelectorTests: XCTestCase {
  func testFolderSelectorUsesGrantAccessAndOneDirectoryOnly() async throws {
    let panel = ProfileAccessOpenPanelDriverSpy(result: nil)
    let selector = ProfileAccessFolderSelector(
      makePanel: { panel },
      homeDirectory: URL(fileURLWithPath: "/home")
    )
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )

    _ = await selector.selectRoot(for: chrome)

    XCTAssertEqual(panel.prompt, "Grant Access")
    XCTAssertTrue(panel.canChooseDirectories)
    XCTAssertFalse(panel.canChooseFiles)
    XCTAssertFalse(panel.allowsMultipleSelection)
    XCTAssertEqual(
      panel.directoryURL,
      URL(fileURLWithPath: "/home/Library/Application Support/Google/Chrome")
    )
  }

  func testFolderSelectorUsesSanitizedBrowserSpecificMessage() async throws {
    let panel = ProfileAccessOpenPanelDriverSpy(result: nil)
    let selector = ProfileAccessFolderSelector(makePanel: { panel })
    let firefox = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "org.mozilla.firefox")
    )

    _ = await selector.selectRoot(for: firefox)

    XCTAssertEqual(
      panel.message,
      "Select the Firefox data folder containing profiles.ini."
    )
    XCTAssertFalse(panel.message.contains(FileManager.default.homeDirectoryForCurrentUser.path))
  }

  func testFolderSelectorReturnsNilWhenPanelCancels() async throws {
    let panel = ProfileAccessOpenPanelDriverSpy(result: nil)
    let selector = ProfileAccessFolderSelector(makePanel: { panel })
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )

    let selected = await selector.selectRoot(for: chrome)

    XCTAssertNil(selected)
  }

  func testFolderSelectorReturnsSelectedURLUnchanged() async throws {
    let expected = URL(fileURLWithPath: "/chosen/Chrome")
    let panel = ProfileAccessOpenPanelDriverSpy(result: expected)
    let selector = ProfileAccessFolderSelector(makePanel: { panel })
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )

    let selected = await selector.selectRoot(for: chrome)

    XCTAssertEqual(selected, expected)
  }
}

@MainActor
private final class ProfileAccessOpenPanelDriverSpy: ProfileAccessOpenPanelDriving {
  var prompt = ""
  var message = ""
  var canChooseDirectories = false
  var canChooseFiles = true
  var allowsMultipleSelection = true
  var directoryURL: URL?
  let result: URL?

  init(result: URL?) {
    self.result = result
  }

  func begin() async -> URL? { result }
}
