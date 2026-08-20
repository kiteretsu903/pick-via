import Foundation
import Security

public enum DuckDuckGoBuildCompatibility: Equatable, Sendable {
  case unsupported
  case ordinaryOnly
  case fire
}

public struct SignedApplicationMetadata: Equatable, Sendable {
  public let bundleIdentifier: String?
  public let teamIdentifier: String?
  public let shortVersion: String?
  public let isSandboxed: Bool

  public init(
    bundleIdentifier: String?,
    teamIdentifier: String?,
    shortVersion: String?,
    isSandboxed: Bool
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.teamIdentifier = teamIdentifier
    self.shortVersion = shortVersion
    self.isSandboxed = isSandboxed
  }
}

public protocol SignedApplicationMetadataProviding: Sendable {
  func metadata(for url: URL) -> SignedApplicationMetadata?
}

public struct SystemSignedApplicationMetadataProvider: SignedApplicationMetadataProviding {
  public init() {}

  public func metadata(for url: URL) -> SignedApplicationMetadata? {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
      let staticCode
    else {
      return nil
    }

    var requirement: SecRequirement?
    guard
      SecRequirementCreateWithString(
        signingRequirement as CFString,
        [],
        &requirement
      ) == errSecSuccess,
      let requirement
    else {
      return nil
    }

    let validityFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
    guard SecStaticCodeCheckValidity(staticCode, validityFlags, requirement) == errSecSuccess else {
      return nil
    }

    var signingInformation: CFDictionary?
    guard
      SecCodeCopySigningInformation(
        staticCode,
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &signingInformation
      ) == errSecSuccess,
      let signingInformation,
      let information = signingInformation as? [String: Any]
    else {
      return nil
    }

    return signedApplicationMetadata(from: information)
  }
}

let signingRequirement =
  "anchor apple generic and identifier \"com.duckduckgo.macos.browser\" and certificate leaf[subject.OU] = \"HKE973VLUW\""

func signedApplicationMetadata(from information: [String: Any]) -> SignedApplicationMetadata? {
  guard let bundleIdentifier = information[kSecCodeInfoIdentifier as String] as? String,
    let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String
  else {
    return nil
  }

  let plist = information[kSecCodeInfoPList as String] as? [String: Any]
  let shortVersion = plist?["CFBundleShortVersionString"] as? String
  let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
  let isSandboxed = entitlements?["com.apple.security.app-sandbox"] as? Bool == true

  return SignedApplicationMetadata(
    bundleIdentifier: bundleIdentifier,
    teamIdentifier: teamIdentifier,
    shortVersion: shortVersion,
    isSandboxed: isSandboxed
  )
}

public protocol DuckDuckGoBuildCompatibilityChecking: Sendable {
  func compatibility(of url: URL) -> DuckDuckGoBuildCompatibility
}

public struct DuckDuckGoBuildCompatibilityChecker: DuckDuckGoBuildCompatibilityChecking {
  public static let bundleIdentifier = "com.duckduckgo.macos.browser"
  public static let teamIdentifier = "HKE973VLUW"

  private let metadataProvider: any SignedApplicationMetadataProviding
  private let allowedVersions: Set<String>

  public init(
    metadataProvider: any SignedApplicationMetadataProviding =
      SystemSignedApplicationMetadataProvider(),
    allowedVersions: Set<String> = ["1.203.0"]
  ) {
    self.metadataProvider = metadataProvider
    self.allowedVersions = allowedVersions
  }

  public func compatibility(of url: URL) -> DuckDuckGoBuildCompatibility {
    guard let metadata = metadataProvider.metadata(for: url),
      metadata.bundleIdentifier == Self.bundleIdentifier,
      metadata.teamIdentifier == Self.teamIdentifier
    else {
      return .unsupported
    }

    guard !metadata.isSandboxed,
      let shortVersion = metadata.shortVersion,
      allowedVersions.contains(shortVersion)
    else {
      return .ordinaryOnly
    }

    return .fire
  }
}
