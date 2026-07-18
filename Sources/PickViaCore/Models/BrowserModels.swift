import Foundation

public enum BrowserFamily: String, Codable, Sendable {
  case safari
  case chromium
  case firefox
}

public enum BrowserMode: String, Codable, Sendable {
  case normal
  case `private`
}

public struct BrowserApplication: Codable, Equatable, Identifiable, Sendable {
  public typealias ID = String

  public let id: ID
  public let family: BrowserFamily
  public let displayName: String
  public let bundleIdentifier: String
  public let applicationURL: URL
  public let executableURL: URL?
  public let isAvailable: Bool

  public init(
    id: ID,
    family: BrowserFamily,
    displayName: String,
    bundleIdentifier: String,
    applicationURL: URL,
    executableURL: URL?,
    isAvailable: Bool
  ) {
    self.id = id
    self.family = family
    self.displayName = displayName
    self.bundleIdentifier = bundleIdentifier
    self.applicationURL = applicationURL
    self.executableURL = executableURL
    self.isAvailable = isAvailable
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case family
    case displayName
    case bundleIdentifier
    case isAvailable
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(ID.self, forKey: .id)
    family = try container.decode(BrowserFamily.self, forKey: .family)
    displayName = try container.decode(String.self, forKey: .displayName)
    bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
    isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
    applicationURL = URL(fileURLWithPath: "/", isDirectory: true)
    executableURL = nil
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(family, forKey: .family)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
    try container.encode(isAvailable, forKey: .isAvailable)
  }
}

public enum BrowserTargetOrigin: String, Codable, Sendable {
  case detected
  case manual
}

public enum BrowserTargetAvailability: String, Codable, Sendable {
  case available
  case unavailable
}

public struct BrowserTarget: Codable, Equatable, Identifiable, Sendable {
  public typealias ID = String

  public let id: ID
  public let browserID: BrowserApplication.ID
  public let label: String
  public let profileIdentifier: String?
  public let profileDisplayName: String?
  public let profileIdentity: String?
  public let profileLaunchPath: String?
  public let mode: BrowserMode
  public let isEnabled: Bool
  public let sortOrder: Int
  public let origin: BrowserTargetOrigin
  public let availability: BrowserTargetAvailability
  public let pendingDefaultMigration: Bool
  public let validationError: String?

  public init(
    id: ID,
    browserID: BrowserApplication.ID,
    label: String,
    profileIdentifier: String?,
    profileDisplayName: String?,
    profileIdentity: String? = nil,
    profileLaunchPath: String? = nil,
    mode: BrowserMode,
    isEnabled: Bool,
    sortOrder: Int,
    origin: BrowserTargetOrigin,
    availability: BrowserTargetAvailability,
    pendingDefaultMigration: Bool = false,
    validationError: String? = nil
  ) {
    self.id = id
    self.browserID = browserID
    self.label = label
    self.profileIdentifier = profileIdentifier
    self.profileDisplayName = profileDisplayName
    self.profileIdentity = profileIdentity
    self.profileLaunchPath = profileLaunchPath
    self.mode = mode
    self.isEnabled = isEnabled
    self.sortOrder = sortOrder
    self.origin = origin
    self.availability = availability
    self.pendingDefaultMigration = pendingDefaultMigration
    self.validationError = validationError
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case browserID
    case label
    case profileIdentifier
    case profileDisplayName
    case profileIdentity
    case mode
    case isEnabled
    case sortOrder
    case origin
    case availability
    case pendingDefaultMigration
    case validationError
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(ID.self, forKey: .id)
    browserID = try container.decode(BrowserApplication.ID.self, forKey: .browserID)
    label = try container.decode(String.self, forKey: .label)
    profileIdentifier = try container.decodeIfPresent(String.self, forKey: .profileIdentifier)
    profileDisplayName = try container.decodeIfPresent(String.self, forKey: .profileDisplayName)
    profileIdentity = try container.decodeIfPresent(String.self, forKey: .profileIdentity)
    profileLaunchPath = nil
    mode = try container.decode(BrowserMode.self, forKey: .mode)
    isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    sortOrder = try container.decode(Int.self, forKey: .sortOrder)
    origin = try container.decode(BrowserTargetOrigin.self, forKey: .origin)
    availability = try container.decode(BrowserTargetAvailability.self, forKey: .availability)
    pendingDefaultMigration =
      try container.decodeIfPresent(Bool.self, forKey: .pendingDefaultMigration) ?? false
    validationError = try container.decodeIfPresent(String.self, forKey: .validationError)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(browserID, forKey: .browserID)
    try container.encode(label, forKey: .label)
    try container.encodeIfPresent(profileIdentifier, forKey: .profileIdentifier)
    try container.encodeIfPresent(profileDisplayName, forKey: .profileDisplayName)
    try container.encodeIfPresent(profileIdentity, forKey: .profileIdentity)
    try container.encode(mode, forKey: .mode)
    try container.encode(isEnabled, forKey: .isEnabled)
    try container.encode(sortOrder, forKey: .sortOrder)
    try container.encode(origin, forKey: .origin)
    try container.encode(availability, forKey: .availability)
    if pendingDefaultMigration {
      try container.encode(true, forKey: .pendingDefaultMigration)
    }
    try container.encodeIfPresent(validationError, forKey: .validationError)
  }
}
