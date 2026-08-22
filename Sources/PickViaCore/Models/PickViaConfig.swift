import Foundation

public struct PickViaConfig: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 3

  public let schemaVersion: Int
  public let applications: [RoutedApplication]
  public let targets: [RouteTarget]

  public init(
    schemaVersion: Int,
    applications: [RoutedApplication],
    targets: [RouteTarget]
  ) {
    self.schemaVersion = schemaVersion
    self.applications = applications
    self.targets = targets
  }

  public init(
    schemaVersion: Int,
    browsers: [BrowserApplication],
    targets: [BrowserTarget]
  ) {
    self.init(
      schemaVersion: schemaVersion,
      applications: browsers,
      targets: targets
    )
  }

  public var browsers: [RoutedApplication] {
    applications.filter { $0.supports(.web) }
  }

  public var mailApplications: [RoutedApplication] {
    applications.filter { $0.supports(.mail) }
  }

  public static let initial = PickViaConfig(
    schemaVersion: currentSchemaVersion,
    applications: [],
    targets: []
  )

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case applications
    case browsers
    case targets
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)

    if schemaVersion <= 2, container.contains(.browsers) {
      let legacy = try LegacyPickViaConfig(from: decoder)
      self.init(
        schemaVersion: legacy.schemaVersion,
        applications: legacy.browsers.map { browser in
          RoutedApplication(
            id: browser.id,
            displayName: browser.displayName,
            bundleIdentifier: browser.bundleIdentifier,
            capabilities: [
              .browser(family: browser.family, isAvailable: browser.isAvailable)
            ],
            applicationURL: URL(fileURLWithPath: "/", isDirectory: true)
          )
        },
        targets: legacy.targets.map { target in
          RouteTarget(
            id: target.id,
            applicationID: target.browserID,
            label: target.label,
            isEnabled: target.isEnabled,
            sortOrder: target.sortOrder,
            origin: target.origin,
            availability: target.availability,
            capability: .browser(
              BrowserTargetOptions(
                profileIdentifier: target.profileIdentifier,
                profileDisplayName: target.profileDisplayName,
                profileIdentity: target.profileIdentity,
                profileLaunchPath: nil,
                mode: target.mode,
                pendingDefaultMigration: target.pendingDefaultMigration,
                validationError: target.validationError
              )
            )
          )
        }
      )
    } else {
      self.init(
        schemaVersion: schemaVersion,
        applications: try container.decode([RoutedApplication].self, forKey: .applications),
        targets: try container.decode([RouteTarget].self, forKey: .targets)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(applications, forKey: .applications)
    try container.encode(targets, forKey: .targets)
  }

  public func validatedAndMigrated() throws -> PickViaConfig {
    try validatedAndMigrated(descriptors: BrowserDescriptor.supported)
  }

  func validatedAndMigrated(
    descriptors: [BrowserDescriptor]
  ) throws -> PickViaConfig {
    guard (0...Self.currentSchemaVersion).contains(schemaVersion) else {
      throw ConfigDocumentError.unsupportedSchema
    }

    let applicationIDs = applications.map(\.id)
    guard Set(applicationIDs).count == applicationIDs.count else {
      throw ConfigDocumentError.duplicateBrowserIdentity
    }
    let bundleIdentifiers = applications.map(\.bundleIdentifier)
    guard Set(bundleIdentifiers).count == bundleIdentifiers.count else {
      throw ConfigDocumentError.duplicateBrowserIdentity
    }
    let descriptorByBundleIdentifier = Dictionary(
      descriptors.map { ($0.bundleIdentifier, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    for application in applications {
      let routeKinds = application.capabilities.map(\.routeKind)
      guard
        application.id == application.bundleIdentifier,
        !application.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !application.capabilities.isEmpty,
        Set(routeKinds).count == routeKinds.count
      else { throw ConfigDocumentError.invalidBrowser }

      if let browserFamily = application.browserFamily {
        guard
          let descriptor = descriptorByBundleIdentifier[application.bundleIdentifier],
          descriptor.family == browserFamily,
          descriptor.hasCompatibleStrategies
        else { throw ConfigDocumentError.invalidBrowser }
      }
    }

    let targetIDs = targets.map(\.id)
    guard Set(targetIDs).count == targetIDs.count else {
      throw ConfigDocumentError.duplicateTargetIdentity
    }
    let applicationsByID = Dictionary(
      uniqueKeysWithValues: applications.map { ($0.id, $0) }
    )
    for target in targets {
      guard
        let application = applicationsByID[target.applicationID],
        application.supports(target.routeKind),
        !target.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !target.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        target.sortOrder >= 0
      else { throw ConfigDocumentError.invalidTarget }

      switch target.capability {
      case .mail:
        guard
          target.origin == .detected,
          target.id == RouteTarget.mailID(bundleIdentifier: application.bundleIdentifier)
        else { throw ConfigDocumentError.invalidTarget }
      case .browser(let options):
        guard let descriptor = descriptorByBundleIdentifier[application.bundleIdentifier] else {
          throw ConfigDocumentError.invalidTarget
        }
        try validateBrowserTarget(
          target,
          options: options,
          application: application,
          descriptor: descriptor
        )
      }
    }

    let migratedTargets = targets.map { target in
      guard
        schemaVersion < 2,
        target.origin == .detected,
        let application = applicationsByID[target.applicationID],
        let descriptor = descriptorByBundleIdentifier[application.bundleIdentifier],
        Self.hasFileBackedProfiles(descriptor),
        let options = target.browserOptions
      else { return target }

      let hasExplicitProfile =
        options.profileIdentity != nil
        || options.profileIdentifier != nil
        || options.profileDisplayName != nil
        || options.profileLaunchPath != nil
      let shouldEnable = !hasExplicitProfile || options.mode == .normal

      return RouteTarget(
        id: target.id,
        applicationID: target.applicationID,
        label: target.label,
        isEnabled: shouldEnable,
        sortOrder: target.sortOrder,
        origin: target.origin,
        availability: target.availability,
        capability: .browser(
          BrowserTargetOptions(
            profileIdentifier: options.profileIdentifier,
            profileDisplayName: options.profileDisplayName,
            profileIdentity: options.profileIdentity,
            profileLaunchPath: options.profileLaunchPath,
            mode: options.mode,
            pendingDefaultMigration: options.pendingDefaultMigration
              || (hasExplicitProfile && options.mode == .private),
            validationError: options.validationError
          )
        )
      )
    }

    return PickViaConfig(
      schemaVersion: Self.currentSchemaVersion,
      applications: applications,
      targets: migratedTargets
    )
  }

  private func validateBrowserTarget(
    _ target: RouteTarget,
    options: BrowserTargetOptions,
    application: RoutedApplication,
    descriptor: BrowserDescriptor
  ) throws {
    if let profileIdentifier = options.profileIdentifier,
      profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw ConfigDocumentError.invalidTarget
    }
    if let profileDisplayName = options.profileDisplayName,
      profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw ConfigDocumentError.invalidTarget
    }
    if let profileIdentity = options.profileIdentity,
      profileIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw ConfigDocumentError.invalidTarget
    }
    let hasProfileEvidence =
      options.profileIdentifier != nil || options.profileDisplayName != nil
      || options.profileIdentity != nil || options.profileLaunchPath != nil
    guard !hasProfileEvidence || descriptor.supportsProfiles else {
      throw ConfigDocumentError.invalidTarget
    }
    if case .safariShortcut = descriptor.profileStrategy {
      guard options.profileLaunchPath == nil else {
        throw ConfigDocumentError.invalidTarget
      }
    }
    guard options.mode == .normal || descriptor.supportsPrivateMode else {
      throw ConfigDocumentError.invalidTarget
    }
    if options.pendingDefaultMigration {
      let canonicalID = [application.bundleIdentifier, "", options.mode.rawValue]
        .joined(separator: "|")
      let isCanonicalDefault =
        target.id == canonicalID
        && options.profileIdentifier == nil
        && options.profileDisplayName == nil
        && options.profileIdentity == nil
        && options.profileLaunchPath == nil
      let isMigratedPrivateProfile =
        options.mode == .private
        && target.id != canonicalID
        && hasProfileEvidence
      guard
        Self.hasFileBackedProfiles(descriptor),
        target.origin == .detected,
        isCanonicalDefault || isMigratedPrivateProfile
      else { throw ConfigDocumentError.invalidTarget }
    }
  }

  private static func hasFileBackedProfiles(_ descriptor: BrowserDescriptor) -> Bool {
    switch descriptor.profileStrategy {
    case .chromium, .firefox:
      true
    case .none, .safariShortcut:
      false
    }
  }
}

private struct LegacyBrowserApplication: Decodable {
  let id: String
  let family: BrowserFamily
  let displayName: String
  let bundleIdentifier: String
  let isAvailable: Bool

  private enum CodingKeys: String, CodingKey {
    case id
    case family
    case displayName
    case bundleIdentifier
    case isAvailable
  }
}

private struct LegacyBrowserTarget: Decodable {
  let id: String
  let browserID: String
  let label: String
  let profileIdentifier: String?
  let profileDisplayName: String?
  let profileIdentity: String?
  let mode: BrowserMode
  let isEnabled: Bool
  let sortOrder: Int
  let origin: TargetOrigin
  let availability: TargetAvailability
  let pendingDefaultMigration: Bool
  let validationError: String?

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

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    browserID = try container.decode(String.self, forKey: .browserID)
    label = try container.decode(String.self, forKey: .label)
    profileIdentifier = try container.decodeIfPresent(String.self, forKey: .profileIdentifier)
    profileDisplayName = try container.decodeIfPresent(String.self, forKey: .profileDisplayName)
    profileIdentity = try container.decodeIfPresent(String.self, forKey: .profileIdentity)
    mode = try container.decode(BrowserMode.self, forKey: .mode)
    isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
    sortOrder = try container.decode(Int.self, forKey: .sortOrder)
    origin = try container.decode(TargetOrigin.self, forKey: .origin)
    availability = try container.decode(TargetAvailability.self, forKey: .availability)
    pendingDefaultMigration =
      try container.decodeIfPresent(Bool.self, forKey: .pendingDefaultMigration) ?? false
    validationError = try container.decodeIfPresent(String.self, forKey: .validationError)
  }
}

private struct LegacyPickViaConfig: Decodable {
  let schemaVersion: Int
  let browsers: [LegacyBrowserApplication]
  let targets: [LegacyBrowserTarget]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case browsers
    case targets
  }
}

enum ConfigDocumentError: Error {
  case unsupportedSchema
  case duplicateBrowserIdentity
  case duplicateTargetIdentity
  case invalidBrowser
  case invalidTarget
}
