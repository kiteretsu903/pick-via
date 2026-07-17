import AppKit
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

  func testFolderSelectorPresentsPanelAsSheetOfOwningWizardWindow() async throws {
    let ownerWindow = NSWindow()
    let panel = ProfileAccessOpenPanelDriverSpy(result: nil)
    let selector = ProfileAccessFolderSelector(
      makePanel: { panel },
      ownerWindow: { ownerWindow }
    )
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )

    _ = await selector.selectRoot(for: chrome)

    XCTAssertTrue(panel.ownerWindow === ownerWindow)
  }

  func testFolderSelectorDoesNotBeginASecondSelectionWhileFirstIsOutstanding() async throws {
    let panel = SuspendingProfileAccessOpenPanelDriverSpy()
    var makePanelCallCount = 0
    let selector = ProfileAccessFolderSelector(makePanel: {
      makePanelCallCount += 1
      return panel
    })
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )

    let firstSelection = Task { await selector.selectRoot(for: chrome) }
    await panel.waitForBeginCallCount(1)
    let secondSelection = Task { await selector.selectRoot(for: chrome) }
    for _ in 0..<10 {
      await Task.yield()
    }

    XCTAssertEqual(makePanelCallCount, 1)
    XCTAssertEqual(panel.beginCallCount, 1)

    panel.resolveAll(with: nil)
    _ = await firstSelection.value
    _ = await secondSelection.value
  }

  func testFolderSelectorCancellationOrdersOutPanelAndIgnoresLateSelection() async throws {
    let selectedRoot = URL(fileURLWithPath: "/chosen/Chrome")
    let panel = SuspendingProfileAccessOpenPanelDriverSpy()
    let selector = ProfileAccessFolderSelector(makePanel: { panel })
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )

    let selection = Task { await selector.selectRoot(for: chrome) }
    await panel.waitForBeginCallCount(1)

    selector.cancelSelection()
    XCTAssertEqual(panel.cancelCallCount, 1)

    panel.resolveAll(with: selectedRoot)
    let resolvedSelection = await selection.value
    XCTAssertNil(resolvedSelection)
  }

  func testAppKitDriverReturnsURLOnlyForOKResponse() {
    let selected = URL(fileURLWithPath: "/chosen/Chrome")

    XCTAssertEqual(
      AppKitProfileAccessOpenPanelDriver.selectedURL(
        for: .OK,
        panelURL: selected
      ),
      selected
    )
    XCTAssertNil(
      AppKitProfileAccessOpenPanelDriver.selectedURL(
        for: .cancel,
        panelURL: selected
      )
    )
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
  private(set) weak var ownerWindow: NSWindow?
  let result: URL?

  init(result: URL?) {
    self.result = result
  }

  func beginSheetModal(for ownerWindow: NSWindow?) async -> URL? {
    self.ownerWindow = ownerWindow
    return result
  }
  func cancel() {}
}

@MainActor
private final class SuspendingProfileAccessOpenPanelDriverSpy: ProfileAccessOpenPanelDriving {
  var prompt = ""
  var message = ""
  var canChooseDirectories = false
  var canChooseFiles = true
  var allowsMultipleSelection = true
  var directoryURL: URL?
  private(set) var beginCallCount = 0
  private(set) var cancelCallCount = 0
  private var continuations: [CheckedContinuation<URL?, Never>] = []

  func beginSheetModal(for ownerWindow: NSWindow?) async -> URL? {
    beginCallCount += 1
    return await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func waitForBeginCallCount(_ expectedCount: Int) async {
    while beginCallCount < expectedCount {
      await Task.yield()
    }
  }

  func resolveAll(with result: URL?) {
    let pendingContinuations = continuations
    continuations = []
    for continuation in pendingContinuations {
      continuation.resume(returning: result)
    }
  }

  func cancel() {
    cancelCallCount += 1
  }
}
