import AppKit
import Foundation

public struct BrowserDescriptor: Sendable {
  public let bundleIdentifier: String
  public let family: BrowserFamily
  public let displayName: String
  public let profileRoot: String?
  public let executableRelativePath: String?

  public static let supported: [BrowserDescriptor] = [
    BrowserDescriptor(
      bundleIdentifier: "com.apple.Safari",
      family: .safari,
      displayName: "Safari",
      profileRoot: nil,
      executableRelativePath: nil
    ),
    BrowserDescriptor(
      bundleIdentifier: "com.google.Chrome",
      family: .chromium,
      displayName: "Google Chrome",
      profileRoot: "Library/Application Support/Google/Chrome",
      executableRelativePath: "Contents/MacOS/Google Chrome"
    ),
    BrowserDescriptor(
      bundleIdentifier: "org.chromium.Chromium",
      family: .chromium,
      displayName: "Chromium",
      profileRoot: "Library/Application Support/Chromium",
      executableRelativePath: "Contents/MacOS/Chromium"
    ),
    BrowserDescriptor(
      bundleIdentifier: "com.microsoft.edgemac",
      family: .chromium,
      displayName: "Microsoft Edge",
      profileRoot: "Library/Application Support/Microsoft Edge",
      executableRelativePath: "Contents/MacOS/Microsoft Edge"
    ),
    BrowserDescriptor(
      bundleIdentifier: "com.brave.Browser",
      family: .chromium,
      displayName: "Brave Browser",
      profileRoot: "Library/Application Support/BraveSoftware/Brave-Browser",
      executableRelativePath: "Contents/MacOS/Brave Browser"
    ),
    BrowserDescriptor(
      bundleIdentifier: "com.vivaldi.Vivaldi",
      family: .chromium,
      displayName: "Vivaldi",
      profileRoot: "Library/Application Support/Vivaldi",
      executableRelativePath: "Contents/MacOS/Vivaldi"
    ),
    BrowserDescriptor(
      bundleIdentifier: "org.mozilla.firefox",
      family: .firefox,
      displayName: "Firefox",
      profileRoot: "Library/Application Support/Firefox",
      executableRelativePath: "Contents/MacOS/firefox"
    ),
  ]

  public static func family(forBundleIdentifier bundleIdentifier: String) -> BrowserFamily? {
    supported.first { $0.bundleIdentifier == bundleIdentifier }?.family
  }

  public static func descriptor(forBundleIdentifier bundleIdentifier: String) -> BrowserDescriptor?
  {
    supported.first { $0.bundleIdentifier == bundleIdentifier }
  }
}

public struct DiscoveredBrowser: Equatable, Sendable {
  public let application: RoutedApplication
  public let profiles: [DiscoveredProfile]
  public let metadataStatus: ProfileMetadataStatus

  public init(
    application: RoutedApplication,
    profiles: [DiscoveredProfile],
    metadataStatus: ProfileMetadataStatus = .loaded
  ) {
    self.application = application
    self.profiles = profiles
    self.metadataStatus = metadataStatus
  }
}

public enum ProfileMetadataStatus: Equatable, Sendable {
  case notApplicable
  case metadataAbsent
  case loaded
  case accessRequired
  case accessRevoked
  case metadataDamaged
}

public enum BrowserProfileAccessIssue: Equatable, Sendable {
  case accessRequired(bundleIdentifier: String)
  case accessRevoked(bundleIdentifier: String)
  case metadataDamaged(bundleIdentifier: String)
}

public typealias BrowserDiscoveryWarning = BrowserProfileAccessIssue

public struct BrowserScanResult: Equatable, Sendable {
  public let browsers: [DiscoveredBrowser]
  public let profileAccessIssues: [BrowserProfileAccessIssue]
  public let isAuthoritative: Bool

  public init(
    browsers: [DiscoveredBrowser],
    profileAccessIssues: [BrowserProfileAccessIssue],
    isAuthoritative: Bool = true
  ) {
    self.browsers = browsers
    self.profileAccessIssues = profileAccessIssues
    self.isAuthoritative = isAuthoritative
  }

  public init(
    browsers: [DiscoveredBrowser],
    warnings: [BrowserDiscoveryWarning],
    isAuthoritative: Bool = true
  ) {
    self.init(
      browsers: browsers,
      profileAccessIssues: warnings,
      isAuthoritative: isAuthoritative
    )
  }

  public var warnings: [BrowserDiscoveryWarning] { profileAccessIssues }
}

public protocol ApplicationLocating: Sendable {
  func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
}

public struct WorkspaceApplicationLocator: ApplicationLocating, TrustedApplicationResolving {
  public init() {}

  public func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
  }
}

public protocol BrowserDiscovering: Sendable {
  func scan() throws -> [DiscoveredBrowser]
  func scanResult() -> BrowserScanResult
  func scanResult(for bundleIdentifier: String) -> DiscoveredBrowser?
  func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig
}

extension BrowserDiscovering {
  public func scanResult() -> BrowserScanResult {
    do {
      return BrowserScanResult(browsers: try scan(), warnings: [], isAuthoritative: true)
    } catch {
      return BrowserScanResult(browsers: [], warnings: [], isAuthoritative: false)
    }
  }

  public func scanResult(for bundleIdentifier: String) -> DiscoveredBrowser? {
    scanResult().browsers.first {
      $0.application.bundleIdentifier == bundleIdentifier
    }
  }
}

public struct BrowserCatalog: BrowserDiscovering, Sendable {
  private let descriptors: [BrowserDescriptor]
  private let applicationLocator: any ApplicationLocating
  private let fileSystem: any FileSystem
  private let profileRootAccess: any ProfileRootAccessProviding
  private let homeDirectory: URL

  public init(
    descriptors: [BrowserDescriptor] = BrowserDescriptor.supported,
    applicationLocator: any ApplicationLocating = WorkspaceApplicationLocator(),
    fileSystem: any FileSystem = FoundationFileSystem(),
    profileRootAccess: any ProfileRootAccessProviding = MissingProfileAccessManager(),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.descriptors = descriptors
    self.applicationLocator = applicationLocator
    self.fileSystem = fileSystem
    self.profileRootAccess = profileRootAccess
    self.homeDirectory = homeDirectory
  }

  public func scan() throws -> [DiscoveredBrowser] {
    scanResult().browsers
  }

  public func scanResult() -> BrowserScanResult {
    var issues: [BrowserProfileAccessIssue] = []
    let browsers = descriptors.compactMap { descriptor -> DiscoveredBrowser? in
      guard let result = discover(descriptor) else { return nil }
      if let issue = result.issue { issues.append(issue) }
      return result.browser
    }
    return BrowserScanResult(
      browsers: browsers,
      profileAccessIssues: issues,
      isAuthoritative: true
    )
  }

  public func scanResult(for bundleIdentifier: String) -> DiscoveredBrowser? {
    guard
      let descriptor = descriptors.first(where: {
        $0.bundleIdentifier == bundleIdentifier
      })
    else {
      return nil
    }
    return discover(descriptor)?.browser
  }

  public func reconcile(
    discovered: [DiscoveredBrowser],
    with config: PickViaConfig
  ) -> PickViaConfig {
    Self.reconcile(discovered: discovered, with: config)
  }

  public static func reconcile(
    discovered: [DiscoveredBrowser],
    with config: PickViaConfig
  ) -> PickViaConfig {
    let discoveredApplications = discovered.map { browser in
      replacingBrowserCapability(
        in: config.applications.first { $0.id == browser.application.id },
        with: browser.application
      )
    }
    let discoveredApplicationIDs = Set(discoveredApplications.map(\.id))
    let missingApplications = config.applications
      .filter { !discoveredApplicationIDs.contains($0.id) }
      .map { application in
        guard let family = application.browserFamily else { return application }
        let unavailableBrowser = RoutedApplication(
          id: application.id,
          displayName: application.displayName,
          bundleIdentifier: application.bundleIdentifier,
          capabilities: [.browser(family: family, isAvailable: false)],
          applicationURL: application.applicationURL,
          browserExecutableURL: application.browserExecutableURL
        )
        return replacingBrowserCapability(in: application, with: unavailableBrowser)
      }
    let applications = discoveredApplications + missingApplications
    let browserTargets = config.targets.filter { $0.routeKind == .web }
    let mailTargets = config.targets.filter { $0.routeKind == .mail }

    let existingByID = Dictionary(
      browserTargets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var nextSortOrder = (browserTargets.map(\.sortOrder).max() ?? -1) + 1
    var reconciled: [RouteTarget] = []
    var consumedExistingIDs = Set<RouteTarget.ID>()

    for browser in discovered {
      let candidates = targetCandidates(for: browser)
      for candidate in candidates {
        let canonicalDefaultMatches = legacyCanonicalDefaultMatches(
          for: candidate,
          browser: browser,
          in: browserTargets
        )
        let legacyAbsolutePathMatches = legacyAbsolutePathProfileMatches(
          for: candidate,
          in: browserTargets
        )
        let canonicalExisting = existingByID[candidate.id]
        let legacyCanonicalWinner = canonicalDefaultMatches.min(by: stableCustomizationOrder)
        let preferredCanonical = canonicalExisting.flatMap { existing in
          existing.pendingDefaultMigration && legacyCanonicalWinner != nil ? nil : existing
        }
        let existing =
          preferredCanonical
          ?? legacyCanonicalWinner
          ?? canonicalExisting
          ?? legacyAbsolutePathMatches.min(by: stableCustomizationOrder)
          ?? ((browser.application.browserFamily == .safari || !isBrowserLevelTarget(candidate))
            && hasUniqueMutableProfileName(candidate, among: candidates)
            ? legacyProfileMatch(for: candidate, in: browserTargets) : nil)
        consumedExistingIDs.formUnion(canonicalDefaultMatches.map(\.id))
        if let existing {
          consumedExistingIDs.insert(existing.id)
          consumedExistingIDs.formUnion(legacyAbsolutePathMatches.map(\.id))
          reconciled.append(
            merging(
              candidate,
              preserving: existing,
              pendingDefaultMigration: shouldPreservePendingDefaultMigration(
                from: existing,
                candidate: candidate,
                browser: browser
              )
            ))
        } else {
          reconciled.append(
            RouteTarget(
              id: candidate.id,
              browserID: candidate.applicationID,
              label: candidate.label,
              profileIdentifier: candidate.profileIdentifier,
              profileDisplayName: candidate.profileDisplayName,
              profileIdentity: candidate.profileIdentity,
              profileLaunchPath: candidate.profileLaunchPath,
              mode: candidate.mode,
              isEnabled: candidate.isEnabled,
              sortOrder: nextSortOrder,
              origin: candidate.origin,
              availability: candidate.availability,
              pendingDefaultMigration: shouldMarkPendingDefaultMigration(
                candidate: candidate,
                browser: browser,
                existingTargets: browserTargets
              ),
              validationError: nil
            ))
          nextSortOrder += 1
        }
      }
    }

    let reconciledIDs = Set(reconciled.map(\.id))
    reconciled.append(
      contentsOf: config.targets
        .filter {
          $0.routeKind == .web
            && !reconciledIDs.contains($0.id)
            && !consumedExistingIDs.contains($0.id)
        }
        .map { target in
          preservingAvailability(target, discovered: discovered)
        })

    reconciled.sort {
      if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
      return $0.id < $1.id
    }
    return PickViaConfig(
      schemaVersion: config.schemaVersion,
      applications: applications,
      targets: reconciled + mailTargets
    )
  }

  private static func replacingBrowserCapability(
    in existing: RoutedApplication?,
    with discovered: RoutedApplication
  ) -> RoutedApplication {
    guard let existing else { return discovered }
    guard
      let browserCapability = discovered.capabilities.first(where: {
        $0.routeKind == .web
      })
    else { return existing }

    var replacedBrowserCapability = false
    var capabilities = existing.capabilities.map { capability in
      guard capability.routeKind == .web else { return capability }
      replacedBrowserCapability = true
      return browserCapability
    }
    if !replacedBrowserCapability {
      capabilities.append(browserCapability)
    }
    return RoutedApplication(
      id: discovered.id,
      displayName: discovered.displayName,
      bundleIdentifier: discovered.bundleIdentifier,
      capabilities: capabilities,
      applicationURL: discovered.applicationURL,
      browserExecutableURL: discovered.browserExecutableURL
    )
  }

  public static func targetID(
    bundleIdentifier: String,
    profileIdentifier: String?,
    mode: BrowserMode
  ) -> String {
    [bundleIdentifier, profileIdentifier ?? "", mode.rawValue]
      .joined(separator: "|")
  }

  public static func runtimeSanitizedFallback(_ config: PickViaConfig) -> PickViaConfig {
    let familyByApplicationID = Dictionary(
      uniqueKeysWithValues: config.applications.compactMap { application in
        application.browserFamily.map { (application.id, $0) }
      }
    )
    var usedTargetIDs = Set(
      config.targets.compactMap { target in
        target.routeKind == .web
          && familyByApplicationID[target.applicationID] == .firefox
          ? nil : target.id
      })
    let targets = config.targets.enumerated().map { index, target in
      guard
        target.routeKind == .web,
        familyByApplicationID[target.applicationID] == .firefox
      else {
        return target
      }

      var sanitized = runtimeSanitizedFirefoxTarget(target)
      if !usedTargetIDs.insert(sanitized.id).inserted {
        var attempt = 0
        while true {
          let seed =
            attempt == 0
            ? "\(target.id)#\(index)"
            : "\(target.id)#\(index)#\(attempt)"
          let candidate =
            "firefox-runtime-target|\(FirefoxProfileIdentity.identifier(forLegacyValue: seed))"
          attempt += 1
          guard usedTargetIDs.insert(candidate).inserted else { continue }
          sanitized = copying(sanitized, id: candidate)
          break
        }
      }
      return sanitized
    }
    return PickViaConfig(
      schemaVersion: config.schemaVersion,
      applications: config.applications,
      targets: targets
    )
  }

  static func isProfileBearingFirefoxTarget(_ target: RouteTarget) -> Bool {
    if target.profileIdentifier != nil || target.profileDisplayName != nil
      || target.profileIdentity != nil || target.profileLaunchPath != nil
      || isSensitivePathShaped(target.id)
    {
      return true
    }
    guard target.origin == .detected else { return false }
    return target.id
      != targetID(
        bundleIdentifier: target.applicationID,
        profileIdentifier: nil,
        mode: target.mode
      )
  }

  private static func isBrowserLevelTarget(_ target: RouteTarget) -> Bool {
    target.profileIdentifier == nil
      && target.profileDisplayName == nil
      && target.profileIdentity == nil
      && target.profileLaunchPath == nil
  }

  private func discover(
    _ descriptor: BrowserDescriptor
  ) -> (browser: DiscoveredBrowser, issue: BrowserProfileAccessIssue?)? {
    guard
      let applicationURL = applicationLocator.applicationURL(
        forBundleIdentifier: descriptor.bundleIdentifier
      )
    else {
      return nil
    }

    let application = RoutedApplication(
      id: descriptor.bundleIdentifier,
      displayName: descriptor.displayName,
      bundleIdentifier: descriptor.bundleIdentifier,
      capabilities: [.browser(family: descriptor.family, isAvailable: true)],
      applicationURL: applicationURL,
      browserExecutableURL: descriptor.executableRelativePath.map {
        applicationURL.appending(path: $0)
      }
    )
    let metadata = readProfiles(for: descriptor)
    return (
      DiscoveredBrowser(
        application: application,
        profiles: metadata.profiles,
        metadataStatus: metadata.status
      ),
      issue(for: metadata.status, bundleIdentifier: descriptor.bundleIdentifier)
    )
  }

  private func readProfiles(
    for descriptor: BrowserDescriptor
  ) -> (profiles: [DiscoveredProfile], status: ProfileMetadataStatus) {
    guard let profileRoot = descriptor.profileRoot else { return ([], .notApplicable) }
    let conventionalRoot = homeDirectory.appending(
      path: profileRoot,
      directoryHint: .isDirectory
    )
    let access = profileRootAccess.beginAccess(for: descriptor.bundleIdentifier)
    switch access.state {
    case .revoked:
      return ([], .accessRevoked)
    case .granted:
      guard let lease = access.lease else { return ([], .accessRevoked) }
      defer { lease.end() }
      return readProfiles(
        at: lease.root,
        for: descriptor,
        usesSavedGrant: true
      )
    case .missing:
      return readProfiles(
        at: conventionalRoot,
        for: descriptor,
        usesSavedGrant: false
      )
    }
  }

  private func readProfiles(
    at root: URL,
    for descriptor: BrowserDescriptor,
    usesSavedGrant: Bool
  ) -> (profiles: [DiscoveredProfile], status: ProfileMetadataStatus) {
    guard let marker = BrowserProfileRootValidator.requiredMarker(for: descriptor.family) else {
      return ([], .notApplicable)
    }
    let data: Data
    do {
      data = try fileSystem.read(from: root.appending(path: marker))
    } catch {
      switch ProfileMetadataReadError(error) {
      case .absent:
        return ([], usesSavedGrant ? .accessRevoked : .metadataAbsent)
      case .accessDenied:
        return ([], usesSavedGrant ? .accessRevoked : .accessRequired)
      case .other:
        return ([], .metadataDamaged)
      }
    }

    do {
      switch descriptor.family {
      case .safari:
        return ([], .notApplicable)
      case .chromium:
        return (try ChromiumProfileParser.parse(data: data), .loaded)
      case .firefox:
        guard let text = String(data: data, encoding: .utf8) else {
          return ([], .metadataDamaged)
        }
        return (
          try FirefoxProfileParser.parse(text: text, baseDirectory: root),
          .loaded
        )
      }
    } catch {
      return ([], .metadataDamaged)
    }
  }

  private func issue(
    for status: ProfileMetadataStatus,
    bundleIdentifier: String
  ) -> BrowserProfileAccessIssue? {
    switch status {
    case .notApplicable, .metadataAbsent, .loaded:
      nil
    case .accessRequired:
      .accessRequired(bundleIdentifier: bundleIdentifier)
    case .accessRevoked:
      .accessRevoked(bundleIdentifier: bundleIdentifier)
    case .metadataDamaged:
      .metadataDamaged(bundleIdentifier: bundleIdentifier)
    }
  }

  private static func targetCandidates(for browser: DiscoveredBrowser) -> [RouteTarget] {
    if browser.application.browserFamily == .safari {
      return [candidate(browser: browser.application, profile: nil, mode: .normal)]
    }

    let defaults = [
      candidate(browser: browser.application, profile: nil, mode: .normal),
      candidate(browser: browser.application, profile: nil, mode: .private),
    ]
    let explicitProfiles: [DiscoveredProfile]
    switch browser.metadataStatus {
    case .notApplicable, .metadataAbsent, .loaded:
      let profiles = uniqueProfiles(browser.profiles)
      let markedDefaults = profiles.filter(\.isDefault)
      let absorbedID = markedDefaults.count == 1 ? markedDefaults[0].identifier : nil
      explicitProfiles = profiles.filter { $0.identifier != absorbedID }
    case .accessRequired, .accessRevoked, .metadataDamaged:
      explicitProfiles = []
    }

    return defaults
      + explicitProfiles.flatMap { profile in
        [
          candidate(browser: browser.application, profile: profile, mode: .normal),
          candidate(browser: browser.application, profile: profile, mode: .private),
        ]
      }
  }

  private static func candidate(
    browser: RoutedApplication,
    profile: DiscoveredProfile?,
    mode: BrowserMode
  ) -> RouteTarget {
    let baseLabel = profile?.displayName ?? browser.displayName
    let label = mode == .private ? "\(baseLabel) Private" : baseLabel
    return RouteTarget(
      id: targetID(
        bundleIdentifier: browser.bundleIdentifier,
        profileIdentifier: profile?.identifier,
        mode: mode
      ),
      browserID: browser.id,
      label: label,
      profileIdentifier: profile?.launchIdentifier,
      profileDisplayName: profile?.displayName,
      profileIdentity: profile?.identifier,
      profileLaunchPath: profile?.directoryURL?.standardizedFileURL.path,
      mode: mode,
      isEnabled: profile == nil || mode == .normal,
      sortOrder: 0,
      origin: .detected,
      availability: .available
    )
  }

  private static func merging(
    _ discovered: RouteTarget,
    preserving existing: RouteTarget,
    pendingDefaultMigration: Bool
  ) -> RouteTarget {
    RouteTarget(
      id: discovered.id,
      browserID: discovered.applicationID,
      label: existing.label,
      profileIdentifier: discovered.profileIdentifier,
      profileDisplayName: discovered.profileDisplayName,
      profileIdentity: discovered.profileIdentity,
      profileLaunchPath: discovered.profileLaunchPath,
      mode: discovered.mode,
      isEnabled:
        existing.pendingDefaultMigration
          && isBrowserLevelTarget(discovered)
          && !isBrowserLevelTarget(existing)
        ? discovered.isEnabled : existing.isEnabled,
      sortOrder: existing.sortOrder,
      origin: existing.origin,
      availability: .available,
      pendingDefaultMigration: pendingDefaultMigration,
      validationError: nil
    )
  }

  private static func preservingAvailability(
    _ target: RouteTarget,
    discovered: [DiscoveredBrowser]
  ) -> RouteTarget {
    let targetFamily =
      discovered.first(where: { $0.application.id == target.applicationID })?
      .application.browserFamily
      ?? BrowserDescriptor.family(forBundleIdentifier: target.applicationID)
    let availability: TargetAvailability
    var resolvedProfile: DiscoveredProfile?
    var refreshesMutableLaunchSelector = false
    if let browser = discovered.first(where: { $0.application.id == target.applicationID }),
      browser.application.isAvailable(for: .web),
      let browserFamily = browser.application.browserFamily,
      BrowserDescriptor.supported.contains(where: {
        $0.bundleIdentifier == browser.application.bundleIdentifier
          && $0.family == browserFamily
      })
    {
      switch browser.metadataStatus {
      case .metadataDamaged:
        return preservingWithoutAuthoritativeMetadata(
          target,
          family: browserFamily
        )
      case .accessRequired, .accessRevoked:
        switch browserFamily {
        case .safari:
          if target.origin == .manual {
            return preservingWithoutAuthoritativeMetadata(
              target,
              family: browserFamily
            )
          }
          availability =
            target.profileIdentity == nil && target.profileIdentifier == nil
            ? .available : .unavailable
        case .chromium, .firefox:
          if isBrowserLevelTarget(target) {
            availability = .available
          } else if target.origin == .manual {
            return preservingWithoutAuthoritativeMetadata(
              target,
              family: browserFamily
            )
          } else {
            availability = .unavailable
          }
        }
      case .notApplicable, .metadataAbsent, .loaded:
        let profiles = uniqueProfiles(browser.profiles)
        refreshesMutableLaunchSelector = browserFamily == .firefox
        switch browserFamily {
        case .safari:
          availability =
            target.profileIdentifier == nil && target.mode == .normal
            ? .available
            : .unavailable
        case .chromium, .firefox:
          if isBrowserLevelTarget(target) {
            availability = .available
          } else {
            if let profileIdentity = target.profileIdentity {
              if browserFamily == .firefox,
                (profileIdentity as NSString).isAbsolutePath
              {
                let normalizedLegacyPath = URL(
                  fileURLWithPath: profileIdentity,
                  isDirectory: true
                ).standardizedFileURL.path
                resolvedProfile = profiles.first {
                  $0.directoryURL?.standardizedFileURL.path == normalizedLegacyPath
                }
              } else {
                resolvedProfile = profiles.first { $0.identifier == profileIdentity }
              }
            } else if browserFamily == .firefox {
              let nameMatches = profiles.filter {
                $0.launchIdentifier == target.profileIdentifier
              }
              resolvedProfile = nameMatches.count == 1 ? nameMatches[0] : nil
            } else {
              resolvedProfile = profiles.first {
                $0.identifier == target.profileIdentifier
              }
            }
            availability = resolvedProfile == nil ? .unavailable : .available
          }
        }
      }
    } else {
      availability = .unavailable
    }

    let migratedIdentity = migratedProfileIdentity(
      for: target,
      resolvedProfile: resolvedProfile,
      family: targetFamily
    )
    return RouteTarget(
      id: migratedTargetID(
        for: target,
        profileIdentity: migratedIdentity,
        family: targetFamily
      ),
      browserID: target.applicationID,
      label: target.label,
      profileIdentifier: refreshesMutableLaunchSelector
        ? (resolvedProfile?.launchIdentifier ?? target.profileIdentifier)
        : target.profileIdentifier,
      profileDisplayName: refreshesMutableLaunchSelector
        ? (resolvedProfile?.displayName ?? target.profileDisplayName)
        : target.profileDisplayName,
      profileIdentity: migratedIdentity,
      profileLaunchPath: targetFamily == .firefox
        ? (availability == .available
          ? resolvedProfile?.directoryURL?.standardizedFileURL.path : nil)
        : target.profileLaunchPath,
      mode: target.mode,
      isEnabled: target.isEnabled,
      sortOrder: target.sortOrder,
      origin: target.origin,
      availability: availability,
      pendingDefaultMigration: target.pendingDefaultMigration,
      validationError: target.validationError
    )
  }

  private static func legacyProfileMatch(
    for candidate: RouteTarget,
    in targets: [RouteTarget]
  ) -> RouteTarget? {
    targets.first {
      $0.applicationID == candidate.applicationID
        && $0.mode == candidate.mode
        && $0.origin == .detected
        && $0.profileIdentity == nil
        && $0.profileIdentifier == candidate.profileIdentifier
    }
  }

  private static func legacyCanonicalDefaultMatches(
    for candidate: RouteTarget,
    browser: DiscoveredBrowser,
    in targets: [RouteTarget]
  ) -> [RouteTarget] {
    guard
      browser.metadataStatus == .loaded || browser.metadataStatus == .metadataAbsent
    else { return [] }
    guard
      isBrowserLevelTarget(candidate)
    else { return [] }
    let marked = uniqueProfiles(browser.profiles).filter(\.isDefault)
    guard marked.count == 1 else { return [] }
    let profile = marked[0]
    let normalizedPath = profile.directoryURL?.standardizedFileURL.path

    return targets.filter { target in
      guard
        target.applicationID == candidate.applicationID,
        target.mode == candidate.mode,
        target.origin == .detected
      else { return false }
      let legacyIdentityPath: String? = target.profileIdentity.flatMap { identity in
        guard
          browser.application.browserFamily == .firefox,
          (identity as NSString).isAbsolutePath
        else { return nil }
        return URL(fileURLWithPath: identity, isDirectory: true).standardizedFileURL.path
      }
      return target.profileIdentity == profile.identifier
        || (target.profileIdentity == nil
          && (target.profileIdentifier == profile.identifier
            || target.profileIdentifier == profile.launchIdentifier))
        || (normalizedPath != nil
          && (target.profileLaunchPath == normalizedPath
            || legacyIdentityPath == normalizedPath))
    }
  }

  private static func legacyAbsolutePathProfileMatches(
    for candidate: RouteTarget,
    in targets: [RouteTarget]
  ) -> [RouteTarget] {
    guard let candidatePath = candidate.profileLaunchPath else { return [] }
    return targets.filter { target in
      guard
        target.applicationID == candidate.applicationID,
        target.mode == candidate.mode,
        target.origin == .detected,
        let identity = target.profileIdentity,
        (identity as NSString).isAbsolutePath
      else { return false }
      return URL(fileURLWithPath: identity, isDirectory: true).standardizedFileURL.path
        == candidatePath
    }
  }

  private static func stableCustomizationOrder(
    _ lhs: RouteTarget,
    _ rhs: RouteTarget
  ) -> Bool {
    if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
    return lhs.id < rhs.id
  }

  private static func shouldMarkPendingDefaultMigration(
    candidate: RouteTarget,
    browser: DiscoveredBrowser,
    existingTargets: [RouteTarget]
  ) -> Bool {
    guard
      browser.application.browserFamily == .chromium
        || browser.application.browserFamily == .firefox,
      isBrowserLevelTarget(candidate),
      hasNonAuthoritativeProfileMetadata(browser.metadataStatus)
    else { return false }
    return existingTargets.contains { target in
      target.applicationID == candidate.applicationID
        && target.mode == candidate.mode
        && target.origin == .detected
        && !isBrowserLevelTarget(target)
    }
  }

  private static func shouldPreservePendingDefaultMigration(
    from existing: RouteTarget,
    candidate: RouteTarget,
    browser: DiscoveredBrowser
  ) -> Bool {
    existing.pendingDefaultMigration
      && isBrowserLevelTarget(candidate)
      && hasNonAuthoritativeProfileMetadata(browser.metadataStatus)
  }

  private static func hasNonAuthoritativeProfileMetadata(
    _ status: ProfileMetadataStatus
  ) -> Bool {
    switch status {
    case .metadataDamaged, .accessRequired, .accessRevoked:
      true
    case .notApplicable, .metadataAbsent, .loaded:
      false
    }
  }

  private static func migratedProfileIdentity(
    for target: RouteTarget,
    resolvedProfile: DiscoveredProfile?,
    family: BrowserFamily?
  ) -> String? {
    guard family == .firefox else { return target.profileIdentity }
    if let resolvedProfile { return resolvedProfile.identifier }
    guard
      let identity = target.profileIdentity,
      (identity as NSString).isAbsolutePath
    else { return target.profileIdentity }
    return FirefoxProfileIdentity.identifier(
      for: URL(fileURLWithPath: identity, isDirectory: true)
    )
  }

  private static func migratedTargetID(
    for target: RouteTarget,
    profileIdentity: String?,
    family: BrowserFamily?
  ) -> RouteTarget.ID {
    guard
      family == .firefox,
      target.origin == .detected,
      let legacyIdentity = target.profileIdentity,
      (legacyIdentity as NSString).isAbsolutePath
    else { return target.id }
    return targetID(
      bundleIdentifier: target.applicationID,
      profileIdentifier: profileIdentity,
      mode: target.mode
    )
  }

  private static func sanitizingLegacyFirefoxIdentity(
    _ target: RouteTarget,
    family: BrowserFamily
  ) -> RouteTarget {
    guard
      family == .firefox,
      let legacyIdentity = target.profileIdentity,
      (legacyIdentity as NSString).isAbsolutePath
    else { return target }
    let opaqueIdentity = FirefoxProfileIdentity.identifier(
      for: URL(fileURLWithPath: legacyIdentity, isDirectory: true)
    )
    return RouteTarget(
      id: target.origin == .detected
        ? targetID(
          bundleIdentifier: target.applicationID,
          profileIdentifier: opaqueIdentity,
          mode: target.mode
        )
        : target.id,
      browserID: target.applicationID,
      label: target.label,
      profileIdentifier: target.profileIdentifier,
      profileDisplayName: target.profileDisplayName,
      profileIdentity: opaqueIdentity,
      profileLaunchPath: target.profileLaunchPath,
      mode: target.mode,
      isEnabled: target.isEnabled,
      sortOrder: target.sortOrder,
      origin: target.origin,
      availability: target.availability,
      pendingDefaultMigration: target.pendingDefaultMigration,
      validationError: target.validationError
    )
  }

  private static func preservingWithoutAuthoritativeMetadata(
    _ target: RouteTarget,
    family: BrowserFamily
  ) -> RouteTarget {
    let sanitized = sanitizingLegacyFirefoxIdentity(target, family: family)
    switch family {
    case .safari:
      return sanitized
    case .chromium where isBrowserLevelTarget(sanitized),
      .firefox where isBrowserLevelTarget(sanitized):
      return copying(
        sanitized,
        availability: .available,
        profileLaunchPath: sanitized.profileLaunchPath
      )
    case .chromium:
      guard sanitized.profileIdentifier == nil else { return sanitized }
      return copying(
        sanitized,
        availability: .unavailable,
        profileLaunchPath: sanitized.profileLaunchPath
      )
    case .firefox:
      return copying(sanitized, availability: .unavailable, profileLaunchPath: nil)
    }
  }

  private static func hasUniqueMutableProfileName(
    _ candidate: RouteTarget,
    among candidates: [RouteTarget]
  ) -> Bool {
    candidates.filter {
      $0.mode == candidate.mode && $0.profileIdentifier == candidate.profileIdentifier
    }.count == 1
  }

  private static func uniqueProfiles(_ profiles: [DiscoveredProfile]) -> [DiscoveredProfile] {
    let sorted = profiles.sorted {
      if $0.identifier != $1.identifier { return $0.identifier < $1.identifier }
      if $0.launchIdentifier != $1.launchIdentifier {
        return $0.launchIdentifier < $1.launchIdentifier
      }
      return $0.displayName < $1.displayName
    }
    var indexByIdentifier: [String: Int] = [:]
    var unique: [DiscoveredProfile] = []
    for profile in sorted {
      if let index = indexByIdentifier[profile.identifier] {
        guard profile.isDefault, !unique[index].isDefault else { continue }
        let representative = unique[index]
        unique[index] = DiscoveredProfile(
          identifier: representative.identifier,
          displayName: representative.displayName,
          directoryURL: representative.directoryURL,
          launchIdentifier: representative.launchIdentifier,
          isDefault: true
        )
      } else {
        indexByIdentifier[profile.identifier] = unique.count
        unique.append(profile)
      }
    }
    return unique
  }

  private static func runtimeSanitizedFirefoxTarget(_ target: RouteTarget) -> RouteTarget {
    let wasProfiled = isProfileBearingFirefoxTarget(target)
    let sanitizedIdentity: String?
    if let identity = target.profileIdentity,
      FirefoxProfileIdentity.isOpaqueIdentifier(identity)
    {
      sanitizedIdentity = identity
    } else if let identity = target.profileIdentity,
      isSensitivePathShaped(identity)
    {
      let decoded = identity.removingPercentEncoding ?? identity
      sanitizedIdentity =
        (decoded as NSString).isAbsolutePath
        ? FirefoxProfileIdentity.identifier(
          for: URL(fileURLWithPath: decoded, isDirectory: true)
        )
        : FirefoxProfileIdentity.identifier(forLegacyValue: decoded)
    } else {
      sanitizedIdentity = nil
    }

    let profileIdentifier = target.profileIdentifier.flatMap {
      isSensitivePathShaped($0) ? nil : $0
    }
    let profileDisplayName = target.profileDisplayName.flatMap {
      isSensitivePathShaped($0) ? nil : $0
    }
    let sanitizedID: RouteTarget.ID
    if target.origin == .detected, wasProfiled {
      let identityForID =
        sanitizedIdentity ?? profileIdentifier
        ?? FirefoxProfileIdentity.identifier(forLegacyValue: target.id)
      sanitizedID = targetID(
        bundleIdentifier: target.applicationID,
        profileIdentifier: identityForID,
        mode: target.mode
      )
    } else if isSensitivePathShaped(target.id) {
      sanitizedID =
        "firefox-runtime-target|\(FirefoxProfileIdentity.identifier(forLegacyValue: target.id))"
    } else {
      sanitizedID = target.id
    }

    return RouteTarget(
      id: sanitizedID,
      browserID: target.applicationID,
      label: target.label,
      profileIdentifier: profileIdentifier,
      profileDisplayName: profileDisplayName,
      profileIdentity: sanitizedIdentity,
      profileLaunchPath: nil,
      mode: target.mode,
      isEnabled: target.isEnabled,
      sortOrder: target.sortOrder,
      origin: target.origin,
      availability: wasProfiled ? .unavailable : target.availability,
      pendingDefaultMigration: target.pendingDefaultMigration,
      validationError: nil
    )
  }

  private static func copying(
    _ target: RouteTarget,
    id: RouteTarget.ID
  ) -> RouteTarget {
    RouteTarget(
      id: id,
      browserID: target.applicationID,
      label: target.label,
      profileIdentifier: target.profileIdentifier,
      profileDisplayName: target.profileDisplayName,
      profileIdentity: target.profileIdentity,
      profileLaunchPath: target.profileLaunchPath,
      mode: target.mode,
      isEnabled: target.isEnabled,
      sortOrder: target.sortOrder,
      origin: target.origin,
      availability: target.availability,
      pendingDefaultMigration: target.pendingDefaultMigration,
      validationError: target.validationError
    )
  }

  private static func copying(
    _ target: RouteTarget,
    availability: TargetAvailability,
    profileLaunchPath: String?
  ) -> RouteTarget {
    RouteTarget(
      id: target.id,
      browserID: target.applicationID,
      label: target.label,
      profileIdentifier: target.profileIdentifier,
      profileDisplayName: target.profileDisplayName,
      profileIdentity: target.profileIdentity,
      profileLaunchPath: profileLaunchPath,
      mode: target.mode,
      isEnabled: target.isEnabled,
      sortOrder: target.sortOrder,
      origin: target.origin,
      availability: availability,
      pendingDefaultMigration: target.pendingDefaultMigration,
      validationError: target.validationError
    )
  }

  private static func isSensitivePathShaped(_ value: String) -> Bool {
    let decoded = value.removingPercentEncoding ?? value
    let lowercase = decoded.lowercased()
    return decoded.contains("/") || decoded.contains("\\") || decoded.contains("~")
      || lowercase.contains("file:")
  }
}
