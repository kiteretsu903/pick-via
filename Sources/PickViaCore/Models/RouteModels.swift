import Foundation

public enum RouteKind: String, Codable, Equatable, Sendable {
  case web
  case mail
}

public enum ApplicationCapability: Codable, Equatable, Sendable {
  case browser(family: BrowserFamily, isAvailable: Bool)
  case mail(isAvailable: Bool)

  public var routeKind: RouteKind {
    switch self {
    case .browser: .web
    case .mail: .mail
    }
  }

  public var isAvailable: Bool {
    switch self {
    case .browser(_, let value), .mail(let value): value
    }
  }

  private enum Kind: String, Codable {
    case browser
    case mail
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case family
    case isAvailable
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    let isAvailable = try container.decode(Bool.self, forKey: .isAvailable)
    switch kind {
    case .browser:
      self = .browser(
        family: try container.decode(BrowserFamily.self, forKey: .family),
        isAvailable: isAvailable
      )
    case .mail:
      guard !container.contains(.family) else {
        throw DecodingError.dataCorruptedError(
          forKey: .family,
          in: container,
          debugDescription: "Mail capabilities cannot contain a browser family."
        )
      }
      self = .mail(isAvailable: isAvailable)
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .browser(let family, let isAvailable):
      try container.encode(Kind.browser, forKey: .kind)
      try container.encode(family, forKey: .family)
      try container.encode(isAvailable, forKey: .isAvailable)
    case .mail(let isAvailable):
      try container.encode(Kind.mail, forKey: .kind)
      try container.encode(isAvailable, forKey: .isAvailable)
    }
  }
}

public struct RoutedApplication: Codable, Equatable, Identifiable, Sendable {
  public typealias ID = String

  public let id: ID
  public let displayName: String
  public let bundleIdentifier: String
  public let capabilities: [ApplicationCapability]
  public let applicationURL: URL
  public let browserExecutableURL: URL?

  public init(
    id: ID,
    displayName: String,
    bundleIdentifier: String,
    capabilities: [ApplicationCapability],
    applicationURL: URL,
    browserExecutableURL: URL? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.bundleIdentifier = bundleIdentifier
    self.capabilities = capabilities
    self.applicationURL = applicationURL
    self.browserExecutableURL = browserExecutableURL
  }

  public var browserFamily: BrowserFamily? {
    capabilities.compactMap {
      if case .browser(let family, _) = $0 { family } else { nil }
    }.first
  }

  public func supports(_ kind: RouteKind) -> Bool {
    capabilities.contains { $0.routeKind == kind }
  }

  public func isAvailable(for kind: RouteKind) -> Bool {
    capabilities.first { $0.routeKind == kind }?.isAvailable == true
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case bundleIdentifier
    case capabilities
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(ID.self, forKey: .id)
    displayName = try container.decode(String.self, forKey: .displayName)
    bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
    capabilities = try container.decode([ApplicationCapability].self, forKey: .capabilities)
    applicationURL = URL(fileURLWithPath: "/", isDirectory: true)
    browserExecutableURL = nil
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
    try container.encode(capabilities, forKey: .capabilities)
  }
}

public struct BrowserTargetOptions: Codable, Equatable, Sendable {
  public let profileIdentifier: String?
  public let profileDisplayName: String?
  public let profileIdentity: String?
  public let profileLaunchPath: String?
  public let mode: BrowserMode
  public let pendingDefaultMigration: Bool
  public let validationError: String?

  public init(
    profileIdentifier: String?,
    profileDisplayName: String?,
    profileIdentity: String?,
    profileLaunchPath: String?,
    mode: BrowserMode,
    pendingDefaultMigration: Bool,
    validationError: String?
  ) {
    self.profileIdentifier = profileIdentifier
    self.profileDisplayName = profileDisplayName
    self.profileIdentity = profileIdentity
    self.profileLaunchPath = profileLaunchPath
    self.mode = mode
    self.pendingDefaultMigration = pendingDefaultMigration
    self.validationError = validationError
  }

  private enum CodingKeys: String, CodingKey {
    case profileIdentifier
    case profileDisplayName
    case profileIdentity
    case mode
    case pendingDefaultMigration
    case validationError
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    profileIdentifier = try container.decodeIfPresent(String.self, forKey: .profileIdentifier)
    profileDisplayName = try container.decodeIfPresent(
      String.self,
      forKey: .profileDisplayName
    )
    profileIdentity = try container.decodeIfPresent(String.self, forKey: .profileIdentity)
    profileLaunchPath = nil
    mode = try container.decode(BrowserMode.self, forKey: .mode)
    pendingDefaultMigration =
      try container.decodeIfPresent(Bool.self, forKey: .pendingDefaultMigration) ?? false
    validationError = try container.decodeIfPresent(String.self, forKey: .validationError)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(profileIdentifier, forKey: .profileIdentifier)
    try container.encodeIfPresent(profileDisplayName, forKey: .profileDisplayName)
    try container.encodeIfPresent(profileIdentity, forKey: .profileIdentity)
    try container.encode(mode, forKey: .mode)
    if pendingDefaultMigration {
      try container.encode(true, forKey: .pendingDefaultMigration)
    }
    try container.encodeIfPresent(validationError, forKey: .validationError)
  }
}

public enum RouteTargetCapability: Codable, Equatable, Sendable {
  case browser(BrowserTargetOptions)
  case mail

  private enum Kind: String, Codable {
    case browser
    case mail
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case browserOptions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .browser:
      self = .browser(
        try container.decode(BrowserTargetOptions.self, forKey: .browserOptions)
      )
    case .mail:
      guard !container.contains(.browserOptions) else {
        throw DecodingError.dataCorruptedError(
          forKey: .browserOptions,
          in: container,
          debugDescription: "Mail targets cannot contain browser options."
        )
      }
      self = .mail
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .browser(let options):
      try container.encode(Kind.browser, forKey: .kind)
      try container.encode(options, forKey: .browserOptions)
    case .mail:
      try container.encode(Kind.mail, forKey: .kind)
    }
  }
}

public struct RouteTarget: Codable, Equatable, Identifiable, Sendable {
  public typealias ID = String

  public let id: ID
  public let applicationID: RoutedApplication.ID
  public let label: String
  public let isEnabled: Bool
  public let sortOrder: Int
  public let origin: TargetOrigin
  public let availability: TargetAvailability
  public let capability: RouteTargetCapability

  public init(
    id: ID,
    applicationID: RoutedApplication.ID,
    label: String,
    isEnabled: Bool,
    sortOrder: Int,
    origin: TargetOrigin,
    availability: TargetAvailability,
    capability: RouteTargetCapability
  ) {
    self.id = id
    self.applicationID = applicationID
    self.label = label
    self.isEnabled = isEnabled
    self.sortOrder = sortOrder
    self.origin = origin
    self.availability = availability
    self.capability = capability
  }

  public var routeKind: RouteKind {
    if case .mail = capability { .mail } else { .web }
  }

  public var browserOptions: BrowserTargetOptions? {
    if case .browser(let options) = capability { options } else { nil }
  }

  public static func mailID(bundleIdentifier: String) -> RouteTarget.ID {
    "mailto|\(bundleIdentifier)"
  }
}
