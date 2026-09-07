import Foundation
import Security

public enum DuckDuckGoBuildCompatibility: Equatable, Sendable {
  case unsupported
  case ordinaryOnly
  case fire
}

public struct DuckDuckGoApplicationMetadata: Equatable, Sendable {
  public let bundleIdentifier: String?
  public let isSandboxed: Bool?

  public init(bundleIdentifier: String?, isSandboxed: Bool?) {
    self.bundleIdentifier = bundleIdentifier
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
    guard metadata.isSandboxed == false else { return .ordinaryOnly }
    return .fire
  }

}
