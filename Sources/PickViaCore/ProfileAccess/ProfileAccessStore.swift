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
  private let fileSystem: any FileSystem

  public init(directory: URL, fileSystem: any FileSystem = FoundationFileSystem()) {
    self.directory = directory
    self.fileSystem = fileSystem
  }

  public func bookmark(for bundleIdentifier: String) throws -> Data? {
    try loadDocument().bookmarks[bundleIdentifier]
  }

  public func save(_ bookmark: Data, for bundleIdentifier: String) throws {
    var document = try loadDocument()
    document.bookmarks[bundleIdentifier] = bookmark
    try save(document)
  }

  public func remove(for bundleIdentifier: String) throws {
    var document = try loadDocument()
    document.bookmarks.removeValue(forKey: bundleIdentifier)
    try save(document)
  }

  private var fileURL: URL {
    directory.appending(path: "ProfileAccessBookmarks.json")
  }

  private func loadDocument() throws -> ProfileAccessBookmarkDocument {
    try fileSystem.createDirectory(at: directory)
    guard fileSystem.fileExists(at: fileURL) else {
      return ProfileAccessBookmarkDocument()
    }

    let data = try fileSystem.read(from: fileURL)
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
    try fileSystem.writeAtomically(data, to: temporary)

    if fileSystem.fileExists(at: fileURL) {
      try fileSystem.replaceItem(at: fileURL, with: temporary)
    } else {
      try fileSystem.moveItem(at: temporary, to: fileURL)
    }
  }
}
