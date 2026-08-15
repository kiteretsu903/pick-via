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

public enum TargetOrigin: String, Codable, Sendable {
  case detected
  case manual
}

public enum TargetAvailability: String, Codable, Sendable {
  case available
  case unavailable
}

public typealias BrowserApplication = RoutedApplication
public typealias BrowserTarget = RouteTarget
public typealias BrowserTargetOrigin = TargetOrigin
public typealias BrowserTargetAvailability = TargetAvailability

extension RoutedApplication {
  public init(
    id: ID,
    family: BrowserFamily,
    displayName: String,
    bundleIdentifier: String,
    applicationURL: URL,
    executableURL: URL?,
    isAvailable: Bool
  ) {
    self.init(
      id: id,
      displayName: displayName,
      bundleIdentifier: bundleIdentifier,
      capabilities: [.browser(family: family, isAvailable: isAvailable)],
      applicationURL: applicationURL,
      browserExecutableURL: executableURL
    )
  }

  public var family: BrowserFamily { browserFamily! }
  public var executableURL: URL? { browserExecutableURL }
  public var isAvailable: Bool { isAvailable(for: .web) }
}

extension RouteTarget {
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
    self.init(
      id: id,
      applicationID: browserID,
      label: label,
      isEnabled: isEnabled,
      sortOrder: sortOrder,
      origin: origin,
      availability: availability,
      capability: .browser(
        BrowserTargetOptions(
          profileIdentifier: profileIdentifier,
          profileDisplayName: profileDisplayName,
          profileIdentity: profileIdentity,
          profileLaunchPath: profileLaunchPath,
          mode: mode,
          pendingDefaultMigration: pendingDefaultMigration,
          validationError: validationError
        )
      )
    )
  }

  public var browserID: BrowserApplication.ID { applicationID }
  public var profileIdentifier: String? { browserOptions!.profileIdentifier }
  public var profileDisplayName: String? { browserOptions!.profileDisplayName }
  public var profileIdentity: String? { browserOptions!.profileIdentity }
  public var profileLaunchPath: String? { browserOptions!.profileLaunchPath }
  public var mode: BrowserMode { browserOptions!.mode }
  public var pendingDefaultMigration: Bool { browserOptions!.pendingDefaultMigration }
  public var validationError: String? { browserOptions!.validationError }
}
