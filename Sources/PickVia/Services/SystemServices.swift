import AppKit
import Foundation
import PickViaCore
import ServiceManagement

public enum SchemeStatus: Equatable, Sendable {
  case isDefault
  case notDefault
  case unknown
}

public struct DefaultBrowserStatus: Equatable, Sendable {
  public let http: SchemeStatus
  public let https: SchemeStatus

  public init(http: SchemeStatus, https: SchemeStatus) {
    self.http = http
    self.https = https
  }

  public static let unknown = DefaultBrowserStatus(http: .unknown, https: .unknown)
}

@MainActor
public protocol DefaultBrowserServicing: AnyObject {
  func status() -> DefaultBrowserStatus
  func requestDefault(for schemes: [String]) async throws
}

@MainActor
public final class MacOSDefaultBrowserService: DefaultBrowserServicing {
  private let workspace: NSWorkspace
  private let applicationURL: URL

  public init(
    workspace: NSWorkspace = .shared,
    applicationURL: URL = Bundle.main.bundleURL
  ) {
    self.workspace = workspace
    self.applicationURL = applicationURL
  }

  public func status() -> DefaultBrowserStatus {
    DefaultBrowserStatus(
      http: status(for: "http"),
      https: status(for: "https")
    )
  }

  public func requestDefault(for schemes: [String]) async throws {
    for scheme in schemes {
      try await setDefaultApplication(for: scheme)
    }
  }

  private func status(for scheme: String) -> SchemeStatus {
    guard let sampleURL = URL(string: "\(scheme)://pickvia.invalid") else { return .unknown }

    return Self.status(
      handlerURL: workspace.urlForApplication(toOpen: sampleURL),
      applicationURL: applicationURL,
      bundleIdentifierForURL: { Bundle(url: $0)?.bundleIdentifier }
    )
  }

  static func status(
    handlerURL: URL?,
    applicationURL: URL,
    bundleIdentifierForURL: (URL) -> String?
  ) -> SchemeStatus {
    guard let handlerURL else { return .unknown }
    if normalized(handlerURL) == normalized(applicationURL) {
      return .isDefault
    }
    guard
      let handlerBundleIdentifier = bundleIdentifierForURL(handlerURL),
      let applicationBundleIdentifier = bundleIdentifierForURL(applicationURL)
    else {
      return .notDefault
    }
    return handlerBundleIdentifier == applicationBundleIdentifier ? .isDefault : .notDefault
  }

  private static func normalized(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func setDefaultApplication(for scheme: String) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      workspace.setDefaultApplication(
        at: applicationURL,
        toOpenURLsWithScheme: scheme
      ) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

@MainActor
public protocol LoginItemServicing: AnyObject {
  var isEnabled: Bool { get }
  func setEnabled(_ enabled: Bool) throws
}

@MainActor
public final class MacOSLoginItemService: LoginItemServicing {
  private let service: SMAppService

  public init(service: SMAppService = .mainApp) {
    self.service = service
  }

  public var isEnabled: Bool {
    service.status == .enabled
  }

  public func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try service.register()
    } else {
      try service.unregister()
    }
  }
}

@MainActor
public protocol PreferencesStoring: AnyObject {
  func bool(forKey key: String) -> Bool?
  func integer(forKey key: String) -> Int?
  func set(_ value: Bool, forKey key: String)
  func set(_ value: Int, forKey key: String)
}

@MainActor
public final class UserDefaultsPreferences: PreferencesStoring {
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func bool(forKey key: String) -> Bool? {
    guard defaults.object(forKey: key) != nil else { return nil }
    return defaults.bool(forKey: key)
  }

  public func integer(forKey key: String) -> Int? {
    guard defaults.object(forKey: key) != nil else { return nil }
    return defaults.integer(forKey: key)
  }

  public func set(_ value: Bool, forKey key: String) {
    defaults.set(value, forKey: key)
  }

  public func set(_ value: Int, forKey key: String) {
    defaults.set(value, forKey: key)
  }
}

@MainActor
public protocol AppRouting: AnyObject {
  func accept(_ url: URL)
  func preview(_ url: URL)
  func refreshCurrent()
}

extension AppRouting {
  public func refreshCurrent() {}
}

@MainActor
public final class RoutingCoordinatorAdapter: AppRouting {
  private let coordinator: RoutingCoordinator
  private let previewAction: (URL) -> Void

  public init(
    coordinator: RoutingCoordinator,
    previewAction: @escaping (URL) -> Void
  ) {
    self.coordinator = coordinator
    self.previewAction = previewAction
  }

  public func accept(_ url: URL) {
    coordinator.enqueue(url)
  }

  public func preview(_ url: URL) {
    previewAction(url)
  }

  public func refreshCurrent() {
    coordinator.refreshCurrentPresentation()
  }
}
