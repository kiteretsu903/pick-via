import Foundation

public protocol ProfileAccessStoring: Sendable {
  func bookmark(for bundleIdentifier: String) throws -> Data?
  func save(_ bookmark: Data, for bundleIdentifier: String) throws
  func remove(for bundleIdentifier: String) throws
}

public struct ProfileAccessBookmarkDocument: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var bookmarks: [String: Data]

  public init(schemaVersion: Int = 1, bookmarks: [String: Data] = [:]) {
    self.schemaVersion = schemaVersion
    self.bookmarks = bookmarks
  }
}

public enum ProfileAccessStoreError: Error, Equatable, Sendable {
  case invalidDocument
}

public struct JSONProfileAccessStore: ProfileAccessStoring, Sendable {
  public let directory: URL
  private let state: State

  public init(directory: URL, fileSystem: any FileSystem = FoundationFileSystem()) {
    self.directory = directory
    state = State(fileSystem: fileSystem)
  }

  public func bookmark(for bundleIdentifier: String) throws -> Data? {
    try state.lock.withLock {
      try loadDocument().bookmarks[bundleIdentifier]
    }
  }

  public func save(_ bookmark: Data, for bundleIdentifier: String) throws {
    try state.lock.withLock {
      var document = try loadDocument()
      document.bookmarks[bundleIdentifier] = bookmark
      try save(document)
    }
  }

  public func remove(for bundleIdentifier: String) throws {
    try state.lock.withLock {
      var document = try loadDocument()
      document.bookmarks.removeValue(forKey: bundleIdentifier)
      try save(document)
    }
  }

  private var fileURL: URL {
    directory.appending(path: "ProfileAccessBookmarks.json")
  }

  private func loadDocument() throws -> ProfileAccessBookmarkDocument {
    try state.fileSystem.createDirectory(at: directory)
    guard state.fileSystem.fileExists(at: fileURL) else {
      return ProfileAccessBookmarkDocument()
    }

    let data = try state.fileSystem.read(from: fileURL)
    do {
      let document = try JSONDecoder().decode(ProfileAccessBookmarkDocument.self, from: data)
      guard document.schemaVersion == 1 else {
        throw ProfileAccessStoreError.invalidDocument
      }
      return document
    } catch {
      throw ProfileAccessStoreError.invalidDocument
    }
  }

  private func save(_ document: ProfileAccessBookmarkDocument) throws {
    let temporary = directory.appending(path: "ProfileAccessBookmarks.json.tmp")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(document)
    try state.fileSystem.writeAtomically(data, to: temporary)

    if state.fileSystem.fileExists(at: fileURL) {
      try state.fileSystem.replaceItem(at: fileURL, with: temporary)
    } else {
      try state.fileSystem.moveItem(at: temporary, to: fileURL)
    }
  }

  private final class State: @unchecked Sendable {
    let lock = NSLock()
    let fileSystem: any FileSystem

    init(fileSystem: any FileSystem) {
      self.fileSystem = fileSystem
    }
  }
}
