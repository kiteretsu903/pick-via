import PickViaCore

public enum BrowserSettingsIssueKind: Hashable, Sendable {
  case access
  case missingProfile
}

public struct BrowserSettingsIssueSegment: Equatable, Identifiable, Sendable {
  public let kind: BrowserSettingsIssueKind
  public let count: Int

  public init(kind: BrowserSettingsIssueKind, count: Int) {
    self.kind = kind
    self.count = count
  }

  public var id: BrowserSettingsIssueKind { kind }

  public var text: String {
    switch (kind, count) {
    case (.access, 1): "1 browser needs access"
    case (.access, _): "\(count) browsers need access"
    case (.missingProfile, 1): "1 profile is missing"
    case (.missingProfile, _): "\(count) profiles are missing"
    }
  }
}

public struct BrowserSettingsIssueSummary: Equatable, Sendable {
  public let accessIssueBrowserCount: Int
  public let missingEnabledProfileCount: Int

  public init(accessIssueBrowserCount: Int, missingEnabledProfileCount: Int) {
    self.accessIssueBrowserCount = accessIssueBrowserCount
    self.missingEnabledProfileCount = missingEnabledProfileCount
  }

  public var segments: [BrowserSettingsIssueSegment] {
    var result: [BrowserSettingsIssueSegment] = []
    if accessIssueBrowserCount > 0 {
      result.append(.init(kind: .access, count: accessIssueBrowserCount))
    }
    if missingEnabledProfileCount > 0 {
      result.append(.init(kind: .missingProfile, count: missingEnabledProfileCount))
    }
    return result
  }
}

func makeBrowserSettingsIssueSummary(
  authoritativeScan: BrowserScanResult?,
  metadataOverrides: [String: ProfileMetadataStatus],
  targetedDiscoveries: [String: DiscoveredBrowser] = [:],
  config: PickViaConfig
) -> BrowserSettingsIssueSummary {
  guard let authoritativeScan else {
    return .init(accessIssueBrowserCount: 0, missingEnabledProfileCount: 0)
  }
  var statusByBundleID = Dictionary(
    uniqueKeysWithValues: authoritativeScan.browsers.map {
      ($0.application.bundleIdentifier, $0.metadataStatus)
    }
  )
  for (bundleIdentifier, status) in metadataOverrides {
    statusByBundleID[bundleIdentifier] = status
  }
  let installedByID = Dictionary(
    uniqueKeysWithValues: config.browsers.map { ($0.id, $0) }
  )
  let targetedBundleIDs = Set(targetedDiscoveries.keys)
  let targetedTargetsByID: [BrowserTarget.ID: BrowserTarget]
  if targetedDiscoveries.isEmpty {
    targetedTargetsByID = [:]
  } else {
    let reconciliation = BrowserCatalog.reconcile(
      discovered: targetedDiscoveries.values.sorted {
        $0.application.bundleIdentifier < $1.application.bundleIdentifier
      },
      with: config
    )
    targetedTargetsByID = Dictionary(
      reconciliation.targets.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
  }

  let accessIDs = Set(
    config.browsers.compactMap { browser -> String? in
      guard browser.isAvailable, browser.family != .safari,
        BrowserDescriptor.descriptor(forBundleIdentifier: browser.bundleIdentifier) != nil
      else { return nil }
      switch statusByBundleID[browser.bundleIdentifier] {
      case .accessRequired?, .accessRevoked?: return browser.id
      default: return nil
      }
    })

  let missingCount = config.targets.filter { target in
    guard target.routeKind == .web,
      target.isEnabled, target.availability == .unavailable,
      let browser = installedByID[target.applicationID], browser.isAvailable(for: .web),
      BrowserDescriptor.descriptor(
        forBundleIdentifier: browser.bundleIdentifier
      ) != nil,
      !accessIDs.contains(browser.id)
    else { return false }
    let isProfileSpecific =
      target.profileIdentifier != nil
      || target.profileDisplayName != nil
      || target.profileIdentity != nil
      || target.profileLaunchPath != nil
    guard isProfileSpecific else { return false }
    guard targetedBundleIDs.contains(browser.bundleIdentifier) else { return true }
    guard let targetedTarget = targetedTargetsByID[target.id] else {
      return false
    }
    return targetedTarget.availability == .unavailable
  }.count

  return .init(
    accessIssueBrowserCount: accessIDs.count,
    missingEnabledProfileCount: missingCount
  )
}
