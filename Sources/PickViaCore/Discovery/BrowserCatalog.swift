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
  public let application: BrowserApplication
  public let profiles: [DiscoveredProfile]
  public let metadataStatus: ProfileMetadataStatus

  public init(
    application: BrowserApplication,
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
  case absent
  case loaded
  case unreadable
}

public enum BrowserDiscoveryWarning: Equatable, Sendable {
  case metadataUnreadable(bundleIdentifier: String)
}

public struct BrowserScanResult: Equatable, Sendable {
  public let browsers: [DiscoveredBrowser]
  public let warnings: [BrowserDiscoveryWarning]
  public let isAuthoritative: Bool

  public init(
    browsers: [DiscoveredBrowser],
    warnings: [BrowserDiscoveryWarning],
    isAuthoritative: Bool = true
  ) {
    self.browsers = browsers
    self.warnings = warnings
    self.isAuthoritative = isAuthoritative
  }
}

public protocol ApplicationLocating: Sendable {
  func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
}

public struct WorkspaceApplicationLocator: ApplicationLocating, TrustedBrowserResolving {
  public init() {}

  public func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
  }
}

public protocol BrowserDiscovering: Sendable {
  func scan() throws -> [DiscoveredBrowser]
  func scanResult() -> BrowserScanResult
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
}

public struct BrowserCatalog: BrowserDiscovering, Sendable {
  private let descriptors: [BrowserDescriptor]
  private let applicationLocator: any ApplicationLocating
  private let fileSystem: any FileSystem
  private let homeDirectory: URL

  public init(
    descriptors: [BrowserDescriptor] = BrowserDescriptor.supported,
    applicationLocator: any ApplicationLocating = WorkspaceApplicationLocator(),
    fileSystem: any FileSystem = FoundationFileSystem(),
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.descriptors = descriptors
    self.applicationLocator = applicationLocator
    self.fileSystem = fileSystem
    self.homeDirectory = homeDirectory
  }

  public func scan() throws -> [DiscoveredBrowser] {
    scanResult().browsers
  }

  public func scanResult() -> BrowserScanResult {
    var warnings: [BrowserDiscoveryWarning] = []
    let browsers = descriptors.compactMap { descriptor -> DiscoveredBrowser? in
      guard
        let applicationURL = applicationLocator.applicationURL(
          forBundleIdentifier: descriptor.bundleIdentifier
        )
      else {
        return nil
      }

      let executableURL = descriptor.executableRelativePath.map {
        applicationURL.appending(path: $0)
      }
      let application = BrowserApplication(
        id: descriptor.bundleIdentifier,
        family: descriptor.family,
        displayName: descriptor.displayName,
        bundleIdentifier: descriptor.bundleIdentifier,
        applicationURL: applicationURL,
        executableURL: executableURL,
        isAvailable: true
      )
      do {
        let result = try readProfiles(for: descriptor)
        return DiscoveredBrowser(
          application: application,
          profiles: result.profiles,
          metadataStatus: result.status
        )
      } catch {
        warnings.append(.metadataUnreadable(bundleIdentifier: descriptor.bundleIdentifier))
        return DiscoveredBrowser(
          application: application,
          profiles: [],
          metadataStatus: .unreadable
        )
      }
    }
    return BrowserScanResult(browsers: browsers, warnings: warnings, isAuthoritative: true)
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
    let discoveredApplications = discovered.map(\.application)
    let discoveredApplicationIDs = Set(discoveredApplications.map(\.id))
    let missingApplications = config.browsers
      .filter { !discoveredApplicationIDs.contains($0.id) }
      .map { application in
        BrowserApplication(
          id: application.id,
          family: application.family,
          displayName: application.displayName,
          bundleIdentifier: application.bundleIdentifier,
          applicationURL: application.applicationURL,
          executableURL: application.executableURL,
          isAvailable: false
        )
      }
    let browsers = discoveredApplications + missingApplications

    let existingByID = Dictionary(
      config.targets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var nextSortOrder = (config.targets.map(\.sortOrder).max() ?? -1) + 1
    var reconciled: [BrowserTarget] = []
    var consumedExistingIDs = Set<BrowserTarget.ID>()

    for browser in discovered {
      let candidates = targetCandidates(for: browser)
      for candidate in candidates {
        let existing =
          existingByID[candidate.id]
          ?? legacyProfileMatch(for: candidate, in: config.targets)
        if let existing {
          consumedExistingIDs.insert(existing.id)
          reconciled.append(merging(candidate, preserving: existing))
        } else {
          reconciled.append(
            BrowserTarget(
              id: candidate.id,
              browserID: candidate.browserID,
              label: candidate.label,
              profileIdentifier: candidate.profileIdentifier,
              profileDisplayName: candidate.profileDisplayName,
              profileIdentity: candidate.profileIdentity,
              mode: candidate.mode,
              isEnabled: candidate.isEnabled,
              sortOrder: nextSortOrder,
              origin: candidate.origin,
              availability: candidate.availability,
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
          !reconciledIDs.contains($0.id) && !consumedExistingIDs.contains($0.id)
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
      browsers: browsers,
      targets: reconciled
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

  private func readProfiles(
    for descriptor: BrowserDescriptor
  ) throws -> (profiles: [DiscoveredProfile], status: ProfileMetadataStatus) {
    guard let profileRoot = descriptor.profileRoot else { return ([], .notApplicable) }
    let rootURL = homeDirectory.appending(path: profileRoot, directoryHint: .isDirectory)
    let metadataURL: URL
    switch descriptor.family {
    case .safari:
      return ([], .notApplicable)
    case .chromium:
      metadataURL = rootURL.appending(path: "Local State")
    case .firefox:
      metadataURL = rootURL.appending(path: "profiles.ini")
    }
    guard fileSystem.fileExists(at: metadataURL) else { return ([], .absent) }
    let data = try fileSystem.read(from: metadataURL)
    switch descriptor.family {
    case .safari:
      return ([], .notApplicable)
    case .chromium:
      return (try ChromiumProfileParser.parse(data: data), .loaded)
    case .firefox:
      guard let text = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
      }
      return (try FirefoxProfileParser.parse(text: text, baseDirectory: rootURL), .loaded)
    }
  }

  private static func targetCandidates(for browser: DiscoveredBrowser) -> [BrowserTarget] {
    if browser.application.family == .safari {
      return [
        candidate(
          browser: browser.application,
          profile: nil,
          mode: .normal
        )
      ]
    }
    let profiles: [DiscoveredProfile?] =
      browser.profiles.isEmpty
      ? [nil]
      : browser.profiles.map(Optional.some)
    return profiles.flatMap { profile in
      [
        candidate(browser: browser.application, profile: profile, mode: .normal),
        candidate(browser: browser.application, profile: profile, mode: .private),
      ]
    }
  }

  private static func candidate(
    browser: BrowserApplication,
    profile: DiscoveredProfile?,
    mode: BrowserMode
  ) -> BrowserTarget {
    let baseLabel = profile?.displayName ?? browser.displayName
    let label = mode == .private ? "\(baseLabel) Private" : baseLabel
    return BrowserTarget(
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
      mode: mode,
      isEnabled: mode == .normal,
      sortOrder: 0,
      origin: .detected,
      availability: .available
    )
  }

  private static func merging(
    _ discovered: BrowserTarget,
    preserving existing: BrowserTarget
  ) -> BrowserTarget {
    BrowserTarget(
      id: discovered.id,
      browserID: discovered.browserID,
      label: existing.label,
      profileIdentifier: discovered.profileIdentifier,
      profileDisplayName: discovered.profileDisplayName,
      profileIdentity: discovered.profileIdentity,
      mode: discovered.mode,
      isEnabled: existing.isEnabled,
      sortOrder: existing.sortOrder,
      origin: existing.origin,
      availability: .available,
      validationError: nil
    )
  }

  private static func preservingAvailability(
    _ target: BrowserTarget,
    discovered: [DiscoveredBrowser]
  ) -> BrowserTarget {
    let availability: BrowserTargetAvailability
    var resolvedProfile: DiscoveredProfile?
    var refreshesMutableLaunchSelector = false
    if let browser = discovered.first(where: { $0.application.id == target.browserID }),
      browser.application.isAvailable,
      BrowserDescriptor.supported.contains(where: {
        $0.bundleIdentifier == browser.application.bundleIdentifier
          && $0.family == browser.application.family
      })
    {
      if browser.metadataStatus == .unreadable {
        availability = target.availability
      } else {
        refreshesMutableLaunchSelector = browser.application.family == .firefox
        switch browser.application.family {
        case .safari:
          availability =
            target.profileIdentifier == nil && target.mode == .normal
            ? .available
            : .unavailable
        case .chromium, .firefox:
          if target.profileIdentifier == nil {
            availability = browser.profiles.isEmpty ? .available : .unavailable
          } else {
            let identity = target.profileIdentity ?? target.profileIdentifier
            resolvedProfile = browser.profiles.first {
              $0.identifier == identity || $0.launchIdentifier == target.profileIdentifier
            }
            availability = resolvedProfile == nil ? .unavailable : .available
          }
        }
      }
    } else {
      availability = .unavailable
    }

    return BrowserTarget(
      id: target.id,
      browserID: target.browserID,
      label: target.label,
      profileIdentifier: refreshesMutableLaunchSelector
        ? (resolvedProfile?.launchIdentifier ?? target.profileIdentifier)
        : target.profileIdentifier,
      profileDisplayName: refreshesMutableLaunchSelector
        ? (resolvedProfile?.displayName ?? target.profileDisplayName)
        : target.profileDisplayName,
      profileIdentity: target.profileIdentity,
      mode: target.mode,
      isEnabled: target.isEnabled,
      sortOrder: target.sortOrder,
      origin: target.origin,
      availability: availability,
      validationError: target.validationError
    )
  }

  private static func legacyProfileMatch(
    for candidate: BrowserTarget,
    in targets: [BrowserTarget]
  ) -> BrowserTarget? {
    targets.first {
      $0.browserID == candidate.browserID
        && $0.mode == candidate.mode
        && $0.origin == .detected
        && $0.profileIdentity == nil
        && $0.profileIdentifier == candidate.profileIdentifier
    }
  }
}
