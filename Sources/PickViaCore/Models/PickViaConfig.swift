public struct PickViaConfig: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public let schemaVersion: Int
  public let browsers: [BrowserApplication]
  public let targets: [BrowserTarget]

  public init(
    schemaVersion: Int,
    browsers: [BrowserApplication],
    targets: [BrowserTarget]
  ) {
    self.schemaVersion = schemaVersion
    self.browsers = browsers
    self.targets = targets
  }

  public static let initial = PickViaConfig(
    schemaVersion: currentSchemaVersion,
    browsers: [],
    targets: []
  )

  public func validatedAndMigrated() throws -> PickViaConfig {
    guard (0...Self.currentSchemaVersion).contains(schemaVersion) else {
      throw ConfigDocumentError.unsupportedSchema
    }

    let browserIDs = browsers.map(\.id)
    guard Set(browserIDs).count == browserIDs.count else {
      throw ConfigDocumentError.duplicateBrowserIdentity
    }
    let bundleIdentifiers = browsers.map(\.bundleIdentifier)
    guard Set(bundleIdentifiers).count == bundleIdentifiers.count else {
      throw ConfigDocumentError.duplicateBrowserIdentity
    }

    for browser in browsers {
      guard
        browser.id == browser.bundleIdentifier,
        !browser.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        BrowserDescriptor.family(forBundleIdentifier: browser.bundleIdentifier) == browser.family
      else { throw ConfigDocumentError.invalidBrowser }
    }

    let targetIDs = targets.map(\.id)
    guard Set(targetIDs).count == targetIDs.count else {
      throw ConfigDocumentError.duplicateTargetIdentity
    }
    let knownBrowserIDs = Set(browserIDs)
    for target in targets {
      guard
        knownBrowserIDs.contains(target.browserID),
        !target.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !target.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        target.sortOrder >= 0
      else { throw ConfigDocumentError.invalidTarget }
      if let profileIdentifier = target.profileIdentifier,
        profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        throw ConfigDocumentError.invalidTarget
      }
      if let profileDisplayName = target.profileDisplayName,
        profileDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        throw ConfigDocumentError.invalidTarget
      }
      if let profileIdentity = target.profileIdentity,
        profileIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        throw ConfigDocumentError.invalidTarget
      }
      guard let browser = browsers.first(where: { $0.id == target.browserID }) else {
        throw ConfigDocumentError.invalidTarget
      }
      if browser.family == .safari,
        target.profileIdentifier != nil || target.profileDisplayName != nil
          || target.profileIdentity != nil || target.mode != .normal
      {
        throw ConfigDocumentError.invalidTarget
      }
      if target.pendingDefaultMigration {
        let canonicalID = [browser.bundleIdentifier, "", target.mode.rawValue]
          .joined(separator: "|")
        guard
          browser.family == .chromium || browser.family == .firefox,
          target.origin == .detected,
          target.id == canonicalID,
          target.profileIdentifier == nil,
          target.profileDisplayName == nil,
          target.profileIdentity == nil,
          target.profileLaunchPath == nil
        else { throw ConfigDocumentError.invalidTarget }
      }
    }

    let migratedTargets = targets.map { target in
      guard
        schemaVersion < 2,
        target.origin == .detected,
        let browser = browsers.first(where: { $0.id == target.browserID }),
        browser.family == .chromium || browser.family == .firefox
      else { return target }

      let hasExplicitProfile =
        target.profileIdentity != nil
        || target.profileIdentifier != nil
        || target.profileDisplayName != nil
        || target.profileLaunchPath != nil
      let shouldEnable = !hasExplicitProfile || target.mode == .normal

      return BrowserTarget(
        id: target.id,
        browserID: target.browserID,
        label: target.label,
        profileIdentifier: target.profileIdentifier,
        profileDisplayName: target.profileDisplayName,
        profileIdentity: target.profileIdentity,
        profileLaunchPath: target.profileLaunchPath,
        mode: target.mode,
        isEnabled: shouldEnable,
        sortOrder: target.sortOrder,
        origin: target.origin,
        availability: target.availability,
        pendingDefaultMigration: target.pendingDefaultMigration,
        validationError: target.validationError
      )
    }

    return PickViaConfig(
      schemaVersion: Self.currentSchemaVersion,
      browsers: browsers,
      targets: migratedTargets
    )
  }
}

enum ConfigDocumentError: Error {
  case unsupportedSchema
  case duplicateBrowserIdentity
  case duplicateTargetIdentity
  case invalidBrowser
  case invalidTarget
}
