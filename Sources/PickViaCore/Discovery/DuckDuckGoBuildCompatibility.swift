import Foundation
import Security

public enum DuckDuckGoBuildCompatibility: Equatable, Sendable {
  case unsupported
  case ordinaryOnly
  case fire
}

public struct DuckDuckGoApplicationMetadata: Equatable, Sendable {
  public let bundleIdentifier: String?
  public let shortVersion: String?
  public let isSandboxed: Bool?

  public init(bundleIdentifier: String?, shortVersion: String?, isSandboxed: Bool?) {
    self.bundleIdentifier = bundleIdentifier
    self.shortVersion = shortVersion
    self.isSandboxed = isSandboxed
  }
}

public protocol DuckDuckGoApplicationMetadataProviding: Sendable {
  func metadata(for url: URL) -> DuckDuckGoApplicationMetadata?
}

public struct SystemDuckDuckGoApplicationMetadataProvider: DuckDuckGoApplicationMetadataProviding {
  public init() {}

  public func metadata(for url: URL) -> DuckDuckGoApplicationMetadata? {
    guard let bundle = Bundle(url: url) else { return nil }
    // Read entitlements only to determine whether the disposable-home technique applies.
    // This is not signature validation or a publisher trust requirement.
    var code: SecStaticCode?
    var information: CFDictionary?
    var sandboxed: Bool?
    if SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
      let code,
      SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation),
        &information) == errSecSuccess,
      let values = information as? [String: Any]
    {
      sandboxed = duckDuckGoSandboxStatus(from: values)
    }
    return DuckDuckGoApplicationMetadata(
      bundleIdentifier: bundle.bundleIdentifier,
      shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
      isSandboxed: sandboxed
    )
  }
}

func duckDuckGoSandboxStatus(from information: [String: Any]) -> Bool? {
  guard let raw = information[kSecCodeInfoEntitlementsDict as String] else { return false }
  guard let entitlements = raw as? [String: Any] else { return nil }
  guard let value = entitlements["com.apple.security.app-sandbox"] else { return false }
  return value as? Bool
}

public protocol DuckDuckGoBuildCompatibilityChecking: Sendable {
  func compatibility(of url: URL) -> DuckDuckGoBuildCompatibility
}

public struct DuckDuckGoBuildCompatibilityChecker: DuckDuckGoBuildCompatibilityChecking {
  public static let bundleIdentifier = "com.duckduckgo.macos.browser"
  private let metadataProvider: any DuckDuckGoApplicationMetadataProviding

  public init(
    metadataProvider: any DuckDuckGoApplicationMetadataProviding =
      SystemDuckDuckGoApplicationMetadataProvider()
  ) {
    self.metadataProvider = metadataProvider
  }

  public func compatibility(of url: URL) -> DuckDuckGoBuildCompatibility {
    guard let metadata = metadataProvider.metadata(for: url),
      metadata.bundleIdentifier == Self.bundleIdentifier
    else { return .unsupported }
    guard metadata.isSandboxed == false,
      let version = metadata.shortVersion,
      Self.supportsPrivatePreferences(version: version)
    else { return .ordinaryOnly }
    return .fire
  }

  // The 1.203 release family uses the observed Fire startup preference layout.
  // Permit patch updates; evaluate a new minor/major release before widening this range.
  static func supportsPrivatePreferences(version: String) -> Bool {
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3,
      parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
      let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
    else { return false }
    return major == 1 && minor == 203 && patch >= 0
  }
}
