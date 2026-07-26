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
  func loadOutcome() -> ConfigLoadOutcome
  func save(_ config: PickViaConfig) throws
}

public enum ConfigLoadFailure: Error, Equatable, Sendable {
  case directoryUnavailable
  case readFailed
  case recoveryFailed
}

public enum ConfigLoadOutcome: Equatable, Sendable {
  case missing(PickViaConfig)
  case loaded(PickViaConfig)
  case recoveredCorruption(PickViaConfig)
  case failure(ConfigLoadFailure)

  public var config: PickViaConfig? {
    switch self {
    case .missing(let config), .loaded(let config), .recoveredCorruption(let config): config
    case .failure: nil
    }
  }
}

extension ConfigStoring {
  public func loadOutcome() -> ConfigLoadOutcome {
    do {
      return .loaded(try load())
    } catch {
      return .failure(.readFailed)
    }
  }
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
    switch loadOutcome() {
    case .missing(let config), .loaded(let config), .recoveredCorruption(let config):
      return config
    case .failure(let failure):
      throw failure
    }
  }

  public func loadOutcome() -> ConfigLoadOutcome {
    do {
      try fileSystem.createDirectory(at: directory)
    } catch {
      return .failure(.directoryUnavailable)
    }
    guard fileSystem.fileExists(at: fileURL) else {
      return .missing(.initial)
    }

    let data: Data
    do {
      data = try fileSystem.read(from: fileURL)
    } catch {
      return .failure(.readFailed)
    }

    do {
      let decoded = try JSONDecoder().decode(PickViaConfig.self, from: data)
      return .loaded(try decoded.validatedAndMigrated())
    } catch {
      let quarantine = directory.appending(
        path: "PickViaConfig.json.corrupt-\(Int(now().timeIntervalSince1970))"
      )
      do {
        try fileSystem.moveItem(at: fileURL, to: quarantine)
        return .recoveredCorruption(.initial)
      } catch {
        return .failure(.recoveryFailed)
      }
    }
  }

  public func save(_ config: PickViaConfig) throws {
    let config = try config.validatedAndMigrated()
    guard
      config.targets.allSatisfy({ target in
        guard
          let application = config.applications.first(where: {
            $0.id == target.applicationID
          }),
          application.browserFamily == .firefox,
          let options = target.browserOptions
        else { return true }
        guard !Self.isPathShapedTargetID(target.id) else { return false }
        if let profileIdentity = options.profileIdentity {
          guard FirefoxProfileIdentity.isOpaqueIdentifier(profileIdentity) else {
            return false
          }
          guard target.origin == .detected else { return true }
          return target.id
            == BrowserCatalog.targetID(
              bundleIdentifier: target.applicationID,
              profileIdentifier: profileIdentity,
              mode: options.mode
            )
        }
        guard target.origin == .detected else { return true }
        if let profileIdentifier = options.profileIdentifier {
          return target.availability == .unavailable
            && target.id
              == BrowserCatalog.targetID(
                bundleIdentifier: target.applicationID,
                profileIdentifier: profileIdentifier,
                mode: options.mode
              )
        }
        return target.id
          == BrowserCatalog.targetID(
            bundleIdentifier: target.applicationID,
            profileIdentifier: nil,
            mode: options.mode
          )
      })
    else {
      throw ConfigDocumentError.invalidTarget
    }
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

  private static func isPathShapedTargetID(_ id: RouteTarget.ID) -> Bool {
    let decoded = id.removingPercentEncoding ?? id
    let lowercase = decoded.lowercased()
    return decoded.contains("/") || decoded.contains("\\") || decoded.contains("~")
      || lowercase.contains("file:")
  }
}
