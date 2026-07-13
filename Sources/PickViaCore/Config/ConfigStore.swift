import Foundation

public protocol FileSystem: Sendable {
  func createDirectory(at url: URL) throws
  func fileExists(at url: URL) -> Bool
  func read(from url: URL) throws -> Data
  func writeAtomically(_ data: Data, to url: URL) throws
  func moveItem(at source: URL, to destination: URL) throws
  func replaceItem(at destination: URL, with source: URL) throws
}

public struct FoundationFileSystem: FileSystem, Sendable {
  public init() {}

  public func createDirectory(at url: URL) throws {
    try FileManager.default.createDirectory(
      at: url,
      withIntermediateDirectories: true
    )
  }

  public func fileExists(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  public func read(from url: URL) throws -> Data {
    try Data(contentsOf: url)
  }

  public func writeAtomically(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
  }

  public func moveItem(at source: URL, to destination: URL) throws {
    try FileManager.default.moveItem(at: source, to: destination)
  }

  public func replaceItem(at destination: URL, with source: URL) throws {
    _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
  }
}

public protocol ConfigStoring: Sendable {
  func load() throws -> PickViaConfig
  func save(_ config: PickViaConfig) throws
}

public struct JSONConfigStore: ConfigStoring, Sendable {
  public let directory: URL
  private let now: @Sendable () -> Date
  private let fileSystem: any FileSystem

  public init(
    directory: URL,
    now: @escaping @Sendable () -> Date = Date.init,
    fileSystem: any FileSystem = FoundationFileSystem()
  ) {
    self.directory = directory
    self.now = now
    self.fileSystem = fileSystem
  }

  private var fileURL: URL {
    directory.appending(path: "PickViaConfig.json")
  }

  public func load() throws -> PickViaConfig {
    try fileSystem.createDirectory(at: directory)
    guard fileSystem.fileExists(at: fileURL) else {
      return .initial
    }

    let data = try fileSystem.read(from: fileURL)
    do {
      return try JSONDecoder().decode(PickViaConfig.self, from: data)
    } catch {
      let quarantine = directory.appending(
        path: "PickViaConfig.json.corrupt-\(Int(now().timeIntervalSince1970))"
      )
      try fileSystem.moveItem(at: fileURL, to: quarantine)
      return .initial
    }
  }

  public func save(_ config: PickViaConfig) throws {
    try fileSystem.createDirectory(at: directory)
    let temporary = directory.appending(path: "PickViaConfig.json.tmp")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    try fileSystem.writeAtomically(data, to: temporary)

    if fileSystem.fileExists(at: fileURL) {
      try fileSystem.replaceItem(at: fileURL, with: temporary)
    } else {
      try fileSystem.moveItem(at: temporary, to: fileURL)
    }
  }
}
