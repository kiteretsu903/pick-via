import AppKit
import Foundation

public protocol MailApplicationLocating: Sendable {
  func applicationURLs(toOpen url: URL) throws -> [URL]
}

public protocol MailApplicationResolving: Sendable {
  func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
}

public struct WorkspaceMailApplicationLocator:
  MailApplicationLocating,
  MailApplicationResolving
{
  public init() {}

  public func applicationURLs(toOpen url: URL) throws -> [URL] {
    NSWorkspace.shared.urlsForApplications(toOpen: url)
  }

  public func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
  }
}

public struct DiscoveredMailApplication: Equatable, Sendable {
  public let bundleIdentifier: String
  public let displayName: String
  public let applicationURL: URL

  public init(bundleIdentifier: String, displayName: String, applicationURL: URL) {
    self.bundleIdentifier = bundleIdentifier
    self.displayName = displayName
    self.applicationURL = applicationURL
  }
}

public struct MailScanResult: Equatable, Sendable {
  public let applications: [DiscoveredMailApplication]
  public let isAuthoritative: Bool

  public init(applications: [DiscoveredMailApplication], isAuthoritative: Bool) {
    self.applications = applications
    self.isAuthoritative = isAuthoritative
  }
}

public protocol MailDiscovering: Sendable {
  func scanResult() -> MailScanResult
  func reconcile(_ scan: MailScanResult, with config: PickViaConfig) -> PickViaConfig
  func runtimeSanitizedFallback(_ config: PickViaConfig) -> PickViaConfig
}

extension MailDiscovering {
  public func runtimeSanitizedFallback(_ config: PickViaConfig) -> PickViaConfig {
    config
  }
}

public struct MailCatalog: MailDiscovering, Sendable {
  private let applicationLocator: any MailApplicationLocating & MailApplicationResolving
  private let pickViaBundleIdentifier: String

  public init(
    applicationLocator: any MailApplicationLocating & MailApplicationResolving =
      WorkspaceMailApplicationLocator(),
    pickViaBundleIdentifier: String = Bundle.main.bundleIdentifier ?? ""
  ) {
    self.applicationLocator = applicationLocator
    self.pickViaBundleIdentifier = pickViaBundleIdentifier
  }

  public func scanResult() -> MailScanResult {
    do {
      let applications = try applicationLocator.applicationURLs(
        toOpen: URL(string: "mailto:pickvia-discovery@invalid")!
      )
      var discoveredByBundleIdentifier: [String: DiscoveredMailApplication] = [:]
      for url in applications {
        guard let application = discoveredApplication(at: url) else { continue }
        guard application.bundleIdentifier != pickViaBundleIdentifier else { continue }
        discoveredByBundleIdentifier[application.bundleIdentifier] =
          discoveredByBundleIdentifier[application.bundleIdentifier] ?? application
      }
      return MailScanResult(
        applications: discoveredByBundleIdentifier.values.sorted(by: Self.displayOrder),
        isAuthoritative: true
      )
    } catch {
      return MailScanResult(applications: [], isAuthoritative: false)
    }
  }

  public func reconcile(_ scan: MailScanResult, with config: PickViaConfig) -> PickViaConfig {
    Self.reconcile(scan, with: config)
  }

  public static func reconcile(
    _ scan: MailScanResult,
    with config: PickViaConfig
  ) -> PickViaConfig {
    guard scan.isAuthoritative else { return config }

    let discoveredByBundleIdentifier = Dictionary(
      uniqueKeysWithValues: scan.applications.map { ($0.bundleIdentifier, $0) }
    )
    let applications =
      config.applications.map { application in
        guard let discovered = discoveredByBundleIdentifier[application.bundleIdentifier] else {
          return application.supports(.mail)
            ? replacingMailCapability(in: application, isAvailable: false)
            : application
        }
        return merging(discovered, into: application)
      }
      + scan.applications
      .filter { discoveredByBundleIdentifier[$0.bundleIdentifier] != nil }
      .filter { discovered in
        !config.applications.contains { $0.bundleIdentifier == discovered.bundleIdentifier }
      }
      .map(newMailApplication)

    let discoveredIdentifiers = Set(scan.applications.map(\.bundleIdentifier))
    let existingMailTargetIDs = Set(
      config.targets.lazy.filter { $0.routeKind == .mail }.map(\.id)
    )
    let targets =
      config.targets.map { target in
        guard target.routeKind == .mail else { return target }
        return replacingAvailability(
          of: target,
          isAvailable: discoveredIdentifiers.contains(target.applicationID)
        )
      }
      + newMailTargets(
        for: scan.applications.filter {
          !existingMailTargetIDs.contains(RouteTarget.mailID(bundleIdentifier: $0.bundleIdentifier))
        },
        after: config.targets.lazy.filter { $0.routeKind == .mail }.map(\.sortOrder).max() ?? -1
      )

    return PickViaConfig(
      schemaVersion: config.schemaVersion,
      applications: applications,
      targets: targets
    )
  }

  public func runtimeSanitizedFallback(_ config: PickViaConfig) -> PickViaConfig {
    PickViaConfig(
      schemaVersion: config.schemaVersion,
      applications: config.applications.map { application in
        guard application.supports(.mail) else { return application }
        guard
          let applicationURL = applicationLocator.applicationURL(
            forBundleIdentifier: application.bundleIdentifier
          )
        else {
          return Self.replacingMailCapability(in: application, isAvailable: false)
        }
        return Self.replacingMailCapability(
          in: application,
          isAvailable: true,
          applicationURL: applicationURL.standardizedFileURL
        )
      },
      targets: config.targets
    )
  }

  private func discoveredApplication(at url: URL) -> DiscoveredMailApplication? {
    let standardizedURL = url.standardizedFileURL
    guard standardizedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
      let bundle = Bundle(url: standardizedURL),
      let bundleIdentifier = bundle.bundleIdentifier?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      !bundleIdentifier.isEmpty
    else { return nil }

    let displayName =
      (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
      ?? standardizedURL.deletingPathExtension().lastPathComponent
    return DiscoveredMailApplication(
      bundleIdentifier: bundleIdentifier,
      displayName: displayName,
      applicationURL: standardizedURL
    )
  }

  private static func displayOrder(
    _ lhs: DiscoveredMailApplication,
    _ rhs: DiscoveredMailApplication
  ) -> Bool {
    let comparison = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
    return comparison == .orderedSame
      ? lhs.bundleIdentifier < rhs.bundleIdentifier
      : comparison == .orderedAscending
  }

  private static func merging(
    _ discovered: DiscoveredMailApplication,
    into existing: RoutedApplication
  ) -> RoutedApplication {
    replacingMailCapability(
      in: existing,
      isAvailable: true,
      displayName: discovered.displayName,
      applicationURL: discovered.applicationURL
    )
  }

  private static func newMailApplication(
    _ discovered: DiscoveredMailApplication
  ) -> RoutedApplication {
    RoutedApplication(
      id: discovered.bundleIdentifier,
      displayName: discovered.displayName,
      bundleIdentifier: discovered.bundleIdentifier,
      capabilities: [.mail(isAvailable: true)],
      applicationURL: discovered.applicationURL
    )
  }

  private static func replacingMailCapability(
    in application: RoutedApplication,
    isAvailable: Bool,
    displayName: String? = nil,
    applicationURL: URL? = nil
  ) -> RoutedApplication {
    var replacedMailCapability = false
    var capabilities = application.capabilities.map { capability in
      guard capability.routeKind == .mail else { return capability }
      replacedMailCapability = true
      return .mail(isAvailable: isAvailable)
    }
    if !replacedMailCapability {
      capabilities.append(.mail(isAvailable: isAvailable))
    }
    return RoutedApplication(
      id: application.id,
      displayName: displayName ?? application.displayName,
      bundleIdentifier: application.bundleIdentifier,
      capabilities: capabilities,
      applicationURL: applicationURL ?? application.applicationURL,
      browserExecutableURL: application.browserExecutableURL
    )
  }

  private static func replacingAvailability(
    of target: RouteTarget,
    isAvailable: Bool
  ) -> RouteTarget {
    RouteTarget(
      id: target.id,
      applicationID: target.applicationID,
      label: target.label,
      isEnabled: target.isEnabled,
      sortOrder: target.sortOrder,
      origin: target.origin,
      availability: isAvailable ? .available : .unavailable,
      capability: target.capability
    )
  }

  private static func newMailTargets(
    for applications: [DiscoveredMailApplication],
    after highestExistingSortOrder: Int
  ) -> [RouteTarget] {
    applications.enumerated().map { index, application in
      RouteTarget(
        id: RouteTarget.mailID(bundleIdentifier: application.bundleIdentifier),
        applicationID: application.bundleIdentifier,
        label: application.displayName,
        isEnabled: true,
        sortOrder: highestExistingSortOrder + index + 1,
        origin: .detected,
        availability: .available,
        capability: .mail
      )
    }
  }
}
