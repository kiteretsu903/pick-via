import Foundation
import Testing

@testable import PickViaCore

@Suite("Profile access bookmark store")
struct ProfileAccessStoreTests {
  @Test func missingDocumentReturnsNoBookmark() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONProfileAccessStore(directory: directory)

    #expect(try store.bookmark(for: "com.google.Chrome") == nil)
  }

  @Test func bookmarksForTwoBrowsersRoundTripIndependently() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONProfileAccessStore(directory: directory)

    try store.save(Data("chrome".utf8), for: "com.google.Chrome")
    try store.save(Data("brave".utf8), for: "com.brave.Browser")

    #expect(try store.bookmark(for: "com.google.Chrome") == Data("chrome".utf8))
    #expect(try store.bookmark(for: "com.brave.Browser") == Data("brave".utf8))
  }

  @Test func existingDocumentIsAtomicallyReplacedThroughTemporaryFile() throws {
    let fileSystem = ProfileAccessFileSystemSpy()
    let store = JSONProfileAccessStore(
      directory: URL(fileURLWithPath: "/profile-access"),
      fileSystem: fileSystem
    )
    try store.save(Data("old".utf8), for: "com.google.Chrome")
    fileSystem.removeRecordedOperations()

    try store.save(Data("new".utf8), for: "com.google.Chrome")

    #expect(
      fileSystem.operations == [
        .createDirectory("/profile-access"),
        .read("/profile-access/ProfileAccessBookmarks.json"),
        .write("/profile-access/ProfileAccessBookmarks.json.tmp"),
        .replace(
          destination: "/profile-access/ProfileAccessBookmarks.json",
          source: "/profile-access/ProfileAccessBookmarks.json.tmp"
        ),
      ]
    )
    #expect(try store.bookmark(for: "com.google.Chrome") == Data("new".utf8))
  }

  @Test func failedReplacementPreservesPreviousBookmark() throws {
    let fileSystem = ProfileAccessFileSystemSpy()
    let store = JSONProfileAccessStore(
      directory: URL(fileURLWithPath: "/profile-access"),
      fileSystem: fileSystem
    )
    try store.save(Data("old".utf8), for: "com.google.Chrome")
    fileSystem.replaceError = CocoaError(.fileWriteNoPermission)

    #expect(throws: (any Error).self) {
      try store.save(Data("new".utf8), for: "com.google.Chrome")
    }
    #expect(try store.bookmark(for: "com.google.Chrome") == Data("old".utf8))
  }

  @Test func savingRefreshedBookmarkReplacesOnlyStaleBytes() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONProfileAccessStore(directory: directory)
    try store.save(Data("stale".utf8), for: "com.google.Chrome")
    try store.save(Data("brave".utf8), for: "com.brave.Browser")

    try store.save(Data("refreshed".utf8), for: "com.google.Chrome")

    #expect(try store.bookmark(for: "com.google.Chrome") == Data("refreshed".utf8))
    #expect(try store.bookmark(for: "com.brave.Browser") == Data("brave".utf8))
  }

  @Test func removalKeepsOtherBrowserBookmark() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONProfileAccessStore(directory: directory)
    try store.save(Data("chrome".utf8), for: "com.google.Chrome")
    try store.save(Data("brave".utf8), for: "com.brave.Browser")

    try store.remove(for: "com.google.Chrome")

    #expect(try store.bookmark(for: "com.google.Chrome") == nil)
    #expect(try store.bookmark(for: "com.brave.Browser") == Data("brave".utf8))
  }

  @Test func malformedBookmarkDocumentThrowsWithoutTouchingConfiguration() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let bookmarkURL = directory.appending(path: "ProfileAccessBookmarks.json")
    let configURL = directory.appending(path: "PickViaConfig.json")
    let configBytes = Data("config sentinel".utf8)
    try Data("not json".utf8).write(to: bookmarkURL)
    try configBytes.write(to: configURL)
    let store = JSONProfileAccessStore(directory: directory)

    #expect(throws: ProfileAccessStoreError.invalidDocument) {
      try store.bookmark(for: "com.google.Chrome")
    }
    #expect(try Data(contentsOf: configURL) == configBytes)
    #expect(FileManager.default.fileExists(atPath: bookmarkURL.path))
  }

  @Test func unsupportedSchemaVersionIsRejected() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"bookmarks":{},"schemaVersion":2}"#.utf8).write(
      to: directory.appending(path: "ProfileAccessBookmarks.json")
    )
    let store = JSONProfileAccessStore(directory: directory)

    #expect(throws: ProfileAccessStoreError.invalidDocument) {
      try store.bookmark(for: "com.google.Chrome")
    }
  }

  @Test func documentUsesDeterministicSortedKeysAndBase64Data() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONProfileAccessStore(directory: directory)

    try store.save(Data("chrome".utf8), for: "com.google.Chrome")
    try store.save(Data("brave".utf8), for: "com.brave.Browser")

    let bytes = try Data(
      contentsOf: directory.appending(path: "ProfileAccessBookmarks.json")
    )
    #expect(
      String(decoding: bytes, as: UTF8.self)
        == #"{"bookmarks":{"com.brave.Browser":"YnJhdmU=","com.google.Chrome":"Y2hyb21l"},"schemaVersion":1}"#
    )
  }

  @Test func concurrentSavesPreserveBothBrowserBookmarks() throws {
    let fileSystem = BlockingProfileAccessFileSystem()
    let firstStore = JSONProfileAccessStore(
      directory: URL(fileURLWithPath: "/profile-access"),
      fileSystem: fileSystem
    )
    let secondStore = firstStore
    try firstStore.save(Data("seed".utf8), for: "seed")
    fileSystem.blockNextWrite()
    defer { fileSystem.releaseBlockedWrite() }

    let errors = ConcurrentErrorRecorder()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      do {
        try firstStore.save(Data("chrome".utf8), for: "com.google.Chrome")
      } catch {
        errors.record(error)
      }
    }
    #expect(fileSystem.waitUntilWriteIsBlocked())

    let secondSaveStarted = DispatchSemaphore(value: 0)
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      secondSaveStarted.signal()
      do {
        try secondStore.save(Data("brave".utf8), for: "com.brave.Browser")
      } catch {
        errors.record(error)
      }
    }
    #expect(secondSaveStarted.wait(timeout: .now() + 2) == .success)
    _ = fileSystem.waitForSecondReadWhileWriteIsBlocked()
    fileSystem.releaseBlockedWrite()

    #expect(group.wait(timeout: .now() + 5) == .success)
    #expect(errors.errors.isEmpty)
    #expect(try firstStore.bookmark(for: "com.google.Chrome") == Data("chrome".utf8))
    #expect(try firstStore.bookmark(for: "com.brave.Browser") == Data("brave".utf8))
  }

  @Test func concurrentRemoveAndSavePreserveBothMutations() throws {
    let fileSystem = BlockingProfileAccessFileSystem()
    let firstStore = JSONProfileAccessStore(
      directory: URL(fileURLWithPath: "/profile-access"),
      fileSystem: fileSystem
    )
    let secondStore = firstStore
    try firstStore.save(Data("chrome".utf8), for: "com.google.Chrome")
    try firstStore.save(Data("brave".utf8), for: "com.brave.Browser")
    fileSystem.blockNextWrite()
    defer { fileSystem.releaseBlockedWrite() }

    let errors = ConcurrentErrorRecorder()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      do {
        try firstStore.remove(for: "com.google.Chrome")
      } catch {
        errors.record(error)
      }
    }
    #expect(fileSystem.waitUntilWriteIsBlocked())

    let saveStarted = DispatchSemaphore(value: 0)
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      saveStarted.signal()
      do {
        try secondStore.save(Data("edge".utf8), for: "com.microsoft.edgemac")
      } catch {
        errors.record(error)
      }
    }
    #expect(saveStarted.wait(timeout: .now() + 2) == .success)
    _ = fileSystem.waitForSecondReadWhileWriteIsBlocked()
    fileSystem.releaseBlockedWrite()

    #expect(group.wait(timeout: .now() + 5) == .success)
    #expect(errors.errors.isEmpty)
    #expect(try firstStore.bookmark(for: "com.google.Chrome") == nil)
    #expect(try firstStore.bookmark(for: "com.brave.Browser") == Data("brave".utf8))
    #expect(try firstStore.bookmark(for: "com.microsoft.edgemac") == Data("edge".utf8))
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "ProfileAccessStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

private enum ProfileAccessFileSystemOperation: Equatable {
  case createDirectory(String)
  case read(String)
  case write(String)
  case move(source: String, destination: String)
  case replace(destination: String, source: String)
}

private enum ProfileAccessFileSystemSpyError: Error {
  case missingSource
}

private final class ProfileAccessFileSystemSpy: FileSystem, @unchecked Sendable {
  private let lock = NSLock()
  private var files: [URL: Data] = [:]
  private var recordedOperations: [ProfileAccessFileSystemOperation] = []

  var replaceError: (any Error)?

  var operations: [ProfileAccessFileSystemOperation] {
    lock.withLock { recordedOperations }
  }

  func removeRecordedOperations() {
    lock.withLock { recordedOperations = [] }
  }

  func createDirectory(at url: URL) throws {
    lock.withLock { recordedOperations.append(.createDirectory(url.path)) }
  }

  func fileExists(at url: URL) -> Bool {
    lock.withLock { files[url] != nil }
  }

  func read(from url: URL) throws -> Data {
    try lock.withLock {
      recordedOperations.append(.read(url.path))
      return try #require(files[url])
    }
  }

  func writeAtomically(_ data: Data, to url: URL) throws {
    lock.withLock {
      recordedOperations.append(.write(url.path))
      files[url] = data
    }
  }

  func moveItem(at source: URL, to destination: URL) throws {
    try lock.withLock {
      recordedOperations.append(.move(source: source.path, destination: destination.path))
      guard let data = files.removeValue(forKey: source) else {
        throw ProfileAccessFileSystemSpyError.missingSource
      }
      files[destination] = data
    }
  }

  func replaceItem(at destination: URL, with source: URL) throws {
    try lock.withLock {
      recordedOperations.append(.replace(destination: destination.path, source: source.path))
      if let replaceError { throw replaceError }
      guard let data = files.removeValue(forKey: source) else {
        throw ProfileAccessFileSystemSpyError.missingSource
      }
      files[destination] = data
    }
  }
}

private final class ConcurrentErrorRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedErrors: [any Error] = []

  var errors: [any Error] {
    lock.withLock { recordedErrors }
  }

  func record(_ error: any Error) {
    lock.withLock { recordedErrors.append(error) }
  }
}

private final class BlockingProfileAccessFileSystem: FileSystem, @unchecked Sendable {
  private let lock = NSLock()
  private var files: [URL: Data] = [:]
  private var shouldBlockWrite = false
  private var didBlockWrite = false
  private var readsAfterBlockingEnabled = 0
  private let writeBlocked = DispatchSemaphore(value: 0)
  private let allowBlockedWrite = DispatchSemaphore(value: 0)
  private let secondRead = DispatchSemaphore(value: 0)

  func blockNextWrite() {
    lock.withLock {
      shouldBlockWrite = true
      didBlockWrite = false
      readsAfterBlockingEnabled = 0
    }
  }

  func waitUntilWriteIsBlocked() -> Bool {
    writeBlocked.wait(timeout: .now() + 2) == .success
  }

  func waitForSecondReadWhileWriteIsBlocked() -> Bool {
    secondRead.wait(timeout: .now() + 1) == .success
  }

  func releaseBlockedWrite() {
    allowBlockedWrite.signal()
  }

  func createDirectory(at url: URL) throws {}

  func fileExists(at url: URL) -> Bool {
    lock.withLock { files[url] != nil }
  }

  func read(from url: URL) throws -> Data {
    let result: (Data?, Bool) = lock.withLock {
      if shouldBlockWrite {
        readsAfterBlockingEnabled += 1
      }
      return (files[url], shouldBlockWrite && readsAfterBlockingEnabled == 2)
    }
    if result.1 {
      secondRead.signal()
    }
    guard let data = result.0 else {
      throw ProfileAccessFileSystemSpyError.missingSource
    }
    return data
  }

  func writeAtomically(_ data: Data, to url: URL) throws {
    let blockThisWrite = lock.withLock {
      guard shouldBlockWrite, !didBlockWrite else { return false }
      didBlockWrite = true
      return true
    }
    if blockThisWrite {
      writeBlocked.signal()
      allowBlockedWrite.wait()
    }
    lock.withLock { files[url] = data }
  }

  func moveItem(at source: URL, to destination: URL) throws {
    try lock.withLock {
      guard let data = files.removeValue(forKey: source) else {
        throw ProfileAccessFileSystemSpyError.missingSource
      }
      files[destination] = data
    }
  }

  func replaceItem(at destination: URL, with source: URL) throws {
    try lock.withLock {
      guard let data = files.removeValue(forKey: source) else {
        throw ProfileAccessFileSystemSpyError.missingSource
      }
      files[destination] = data
    }
  }
}
