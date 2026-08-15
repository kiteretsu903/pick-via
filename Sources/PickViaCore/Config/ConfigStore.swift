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

public struct FirefoxPersistenceShape: Equatable, Sendable {
  public let targetID: RouteTarget.ID
  public let profileIdentifier: String?
  public let profileDisplayName: String?
  public let profileIdentity: String?
  public let availability: TargetAvailability

  public init(
    targetID: RouteTarget.ID,
    profileIdentifier: String?,
    profileDisplayName: String?,
    profileIdentity: String?,
    availability: TargetAvailability
  ) {
    self.targetID = targetID
    self.profileIdentifier = profileIdentifier
    self.profileDisplayName = profileDisplayName
    self.profileIdentity = profileIdentity
    self.availability = availability
  }
}

public enum FirefoxPersistencePolicy {
  public static func isForbiddenTargetID(_ id: RouteTarget.ID) -> Bool {
    guard let normalized = normalizedForPathInspection(id) else { return true }
    let lowercase = normalized.lowercased()
    return normalized.contains("/") || normalized.contains("\\") || normalized.contains("~")
      || (normalized as NSString).isAbsolutePath
      || lowercase.contains("file:")
  }

  public static func canonicalShape(
    for target: RouteTarget,
    profileIdentity: String?
  ) -> FirefoxPersistenceShape {
    let wasOriginallyProfileBearing = isOriginallyProfileBearing(target)
    let profileIdentifier = sanitizedProfileValue(target.profileIdentifier)
    let profileDisplayName = sanitizedProfileValue(target.profileDisplayName)

    if let profileIdentity {
      return FirefoxPersistenceShape(
        targetID: target.origin == .detected
          ? BrowserCatalog.targetID(
            bundleIdentifier: target.applicationID,
            profileIdentifier: profileIdentity,
            mode: target.mode
          )
          : target.id,
        profileIdentifier: profileIdentifier,
        profileDisplayName: profileDisplayName,
        profileIdentity: profileIdentity,
        availability: target.availability
      )
    }

    if target.origin == .detected {
      if wasOriginallyProfileBearing, profileIdentifier == nil {
        let placeholderIdentity = FirefoxProfileIdentity.identifier(
          forLegacyValue: "firefox-persistence-placeholder|\(target.id)|\(target.mode.rawValue)"
        )
        return FirefoxPersistenceShape(
          targetID: BrowserCatalog.targetID(
            bundleIdentifier: target.applicationID,
            profileIdentifier: placeholderIdentity,
            mode: target.mode
          ),
          profileIdentifier: nil,
          profileDisplayName: nil,
          profileIdentity: placeholderIdentity,
          availability: .unavailable
        )
      }
      return FirefoxPersistenceShape(
        targetID: BrowserCatalog.targetID(
          bundleIdentifier: target.applicationID,
          profileIdentifier: profileIdentifier,
          mode: target.mode
        ),
        profileIdentifier: profileIdentifier,
        profileDisplayName: profileDisplayName,
        profileIdentity: nil,
        availability: profileIdentifier == nil ? target.availability : .unavailable
      )
    }

    return FirefoxPersistenceShape(
      targetID: target.id,
      profileIdentifier: profileIdentifier,
      profileDisplayName: profileDisplayName,
      profileIdentity: nil,
      availability: target.availability
    )
  }

  public static func isPersistenceSafe(_ target: RouteTarget) -> Bool {
    guard !isForbiddenTargetID(target.id) else { return false }
    guard
      target.profileIdentity == nil
        || FirefoxProfileIdentity.isOpaqueIdentifier(target.profileIdentity!)
    else { return false }

    let shape = canonicalShape(for: target, profileIdentity: target.profileIdentity)
    return target.id == shape.targetID
      && target.profileIdentifier == shape.profileIdentifier
      && target.profileDisplayName == shape.profileDisplayName
      && target.profileIdentity == shape.profileIdentity
      && target.availability == shape.availability
  }

  private static func sanitizedProfileValue(_ value: String?) -> String? {
    guard let value, !isForbiddenTargetID(value) else { return nil }
    return value
  }

  private static func isOriginallyProfileBearing(_ target: RouteTarget) -> Bool {
    target.profileIdentifier != nil
      || target.profileDisplayName != nil
      || target.profileIdentity != nil
      || target.profileLaunchPath != nil
      || isForbiddenTargetID(target.id)
  }

  private static func normalizedForPathInspection(_ value: String) -> String? {
    let maximumUTF8Count = 65_536
    let maximumDecodeCount = 8
    guard value.utf8.count <= maximumUTF8Count else { return nil }

    var normalized = value
    var visited = Set([normalized])
    for _ in 0..<maximumDecodeCount {
      let decoded = decodingValidPercentEscapes(in: normalized)
      guard decoded.utf8.count <= maximumUTF8Count else { return nil }
      guard decoded != normalized else { return normalized }
      guard visited.insert(decoded).inserted else { return nil }
      normalized = decoded
    }

    return containsValidPercentEscape(in: normalized) ? nil : normalized
  }

  private static func decodingValidPercentEscapes(in value: String) -> String {
    let bytes = Array(value.utf8)
    var decoded: [UInt8] = []
    decoded.reserveCapacity(bytes.count)
    var index = 0

    while index < bytes.count {
      if bytes[index] == 0x25,
        index + 2 < bytes.count,
        let high = hexadecimalValue(bytes[index + 1]),
        let low = hexadecimalValue(bytes[index + 2])
      {
        decoded.append((high << 4) | low)
        index += 3
      } else {
        decoded.append(bytes[index])
        index += 1
      }
    }

    return String(decoding: decoded, as: UTF8.self)
  }

  private static func containsValidPercentEscape(in value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count >= 3 else { return false }
    for index in 0...(bytes.count - 3) {
      guard bytes[index] == 0x25 else { continue }
      if hexadecimalValue(bytes[index + 1]) != nil,
        hexadecimalValue(bytes[index + 2]) != nil
      {
        return true
      }
    }
    return false
  }

  private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39:
      byte - 0x30
    case 0x41...0x46:
      byte - 0x41 + 10
    case 0x61...0x66:
      byte - 0x61 + 10
    default:
      nil
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
          let application = config.applications.first(where: { $0.id == target.applicationID }),
          application.browserFamily == .firefox,
          target.browserOptions != nil
        else { return true }
        return FirefoxPersistencePolicy.isPersistenceSafe(target)
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
}
