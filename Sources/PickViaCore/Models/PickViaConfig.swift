public struct PickViaConfig: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

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
    }

    return PickViaConfig(
      schemaVersion: Self.currentSchemaVersion,
      browsers: browsers,
      targets: targets
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
