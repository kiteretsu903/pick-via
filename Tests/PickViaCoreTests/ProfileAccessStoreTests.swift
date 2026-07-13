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
