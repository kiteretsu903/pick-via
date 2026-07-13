import Foundation
import XCTest

@testable import PickViaCore

final class ConfigStoreTests: XCTestCase {
  func testMissingFileReturnsInitialConfiguration() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(directory: directory)

    XCTAssertEqual(try store.load(), .initial)
  }

  func testSaveThenLoadRoundTripsConfiguration() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(
      directory: directory,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    let app = BrowserApplication(
      id: "chrome",
      family: .chromium,
      displayName: "Chrome",
      bundleIdentifier: "com.google.Chrome",
      applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
      executableURL: URL(
        fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
      isAvailable: true
    )
    let target = BrowserTarget(
      id: "chrome-work",
      browserID: app.id,
      label: "工作",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available
    )
    let expected = PickViaConfig(schemaVersion: 1, browsers: [app], targets: [target])

    try store.save(expected)

    XCTAssertEqual(try store.load(), expected)
  }

  func testCorruptFileIsQuarantinedAndReturnsInitialConfiguration() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "PickViaConfig.json")
    try Data("not valid json".utf8).write(to: fileURL)
    let store = JSONConfigStore(
      directory: directory,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    XCTAssertEqual(try store.load(), .initial)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          directory
          .appending(path: "PickViaConfig.json.corrupt-1700000000")
          .path
      )
    )
  }

  func testReadFailureIsPropagatedWithoutQuarantiningConfiguration() {
    let fileSystem = ReadFailingFileSystem()
    let store = JSONConfigStore(
      directory: URL(fileURLWithPath: "/virtual/application-support"),
      fileSystem: fileSystem
    )

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? FileSystemTestError, .readFailed)
    }
    XCTAssertEqual(fileSystem.moveCallCount, 0)
  }

  func testSavingOverExistingFileReplacesConfigurationAndLeavesNoTemporaryFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(directory: directory)
    let first = PickViaConfig(schemaVersion: 1, browsers: [], targets: [])
    let second = PickViaConfig(schemaVersion: 2, browsers: [], targets: [])

    try store.save(first)
    try store.save(second)

    XCTAssertEqual(try store.load(), second)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appending(path: "PickViaConfig.json.tmp").path
      )
    )
  }

  func testSaveLeavesNoTemporaryFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(directory: directory)

    try store.save(.initial)

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appending(path: "PickViaConfig.json.tmp").path
      )
    )
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "PickViaCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

private enum FileSystemTestError: Error, Equatable {
  case readFailed
}

private final class ReadFailingFileSystem: FileSystem, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedMoveCallCount = 0

  var moveCallCount: Int {
    lock.withLock { recordedMoveCallCount }
  }

  func createDirectory(at url: URL) throws {}

  func fileExists(at url: URL) -> Bool {
    true
  }

  func read(from url: URL) throws -> Data {
    throw FileSystemTestError.readFailed
  }

  func writeAtomically(_ data: Data, to url: URL) throws {
    preconditionFailure("Unexpected write")
  }

  func moveItem(at source: URL, to destination: URL) throws {
    lock.withLock {
      recordedMoveCallCount += 1
    }
  }

  func replaceItem(at destination: URL, with source: URL) throws {
    preconditionFailure("Unexpected replacement")
  }
}
