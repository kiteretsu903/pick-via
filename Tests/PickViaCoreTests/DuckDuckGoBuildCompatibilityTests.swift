import Foundation
import Security
import Testing

@testable import PickViaCore

@Suite("DuckDuckGo build compatibility")
struct DuckDuckGoBuildCompatibilityTests {
  private let applicationURL = URL(fileURLWithPath: "/Applications/DuckDuckGo.app")

  @Test func nilMetadataIsUnsupported() {
    let checker = DuckDuckGoBuildCompatibilityChecker(
      metadataProvider: StubMetadataProvider(metadata: nil))

    #expect(checker.compatibility(of: applicationURL) == .unsupported)
  }

  @Test func wrongBundleIdentifierIsUnsupported() {
    let checker = checker(for: metadata(bundleIdentifier: "com.example.browser"))

    #expect(checker.compatibility(of: applicationURL) == .unsupported)
  }

  @Test func wrongTeamIdentifierIsUnsupported() {
    let checker = checker(for: metadata(teamIdentifier: "TEAM123456"))

    #expect(checker.compatibility(of: applicationURL) == .unsupported)
  }

  @Test func validSignedUnknownVersionIsOrdinaryOnly() {
    let checker = checker(for: metadata(shortVersion: "1.204.0"))

    #expect(checker.compatibility(of: applicationURL) == .ordinaryOnly)
  }

  @Test func validAllowlistedSandboxedBuildIsOrdinaryOnly() {
    let checker = checker(for: metadata(isSandboxed: true))

    #expect(checker.compatibility(of: applicationURL) == .ordinaryOnly)
  }

  @Test func validAllowlistedUnsandboxedBuildIsFire() {
    let checker = checker(for: metadata(isSandboxed: false))

    #expect(checker.compatibility(of: applicationURL) == .fire)
  }

  @Test func explicitlyProvidedAllowlistCanEnableMatchingBuild() {
    let checker = DuckDuckGoBuildCompatibilityChecker(
      metadataProvider: StubMetadataProvider(metadata: metadata(shortVersion: "9.9.9")),
      allowedVersions: ["9.9.9"]
    )

    #expect(checker.compatibility(of: applicationURL) == .fire)
  }

  @Test func signedInformationExtractsExactMetadata() {
    let metadata = signedApplicationMetadata(
      from: signingInformation(
        bundleIdentifier: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
        teamIdentifier: DuckDuckGoBuildCompatibilityChecker.teamIdentifier,
        shortVersion: "1.203.0",
        sandboxValue: true
      ))

    #expect(
      metadata
        == SignedApplicationMetadata(
          bundleIdentifier: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
          teamIdentifier: DuckDuckGoBuildCompatibilityChecker.teamIdentifier,
          shortVersion: "1.203.0",
          isSandboxed: true
        )
    )
  }

  @Test func missingSignedPlistIsRejected() {
    var information = signingInformation()
    information.removeValue(forKey: kSecCodeInfoPList as String)

    #expect(signedApplicationMetadata(from: information) == nil)
  }

  @Test func malformedSignedPlistIsRejected() {
    var information = signingInformation()
    information[kSecCodeInfoPList as String] = "not a plist dictionary"

    #expect(signedApplicationMetadata(from: information) == nil)
  }

  @Test func missingSignedIdentifiersAreRejected() {
    var information = signingInformation()
    information.removeValue(forKey: kSecCodeInfoIdentifier as String)
    #expect(signedApplicationMetadata(from: information) == nil)

    information = signingInformation()
    information.removeValue(forKey: kSecCodeInfoTeamIdentifier as String)
    #expect(signedApplicationMetadata(from: information) == nil)
  }

  @Test func nonBooleanSandboxEntitlementIsNotSandboxed() {
    let metadata = signedApplicationMetadata(from: signingInformation(sandboxValue: "true"))

    #expect(metadata?.isSandboxed == false)
  }

  @Test func falseSandboxEntitlementIsNotSandboxed() {
    let metadata = signedApplicationMetadata(from: signingInformation(sandboxValue: false))

    #expect(metadata?.isSandboxed == false)
  }

  @Test func absentSandboxEntitlementIsNotSandboxed() {
    let metadata = signedApplicationMetadata(from: signingInformation(sandboxValue: nil))

    #expect(metadata?.isSandboxed == false)
  }

  @Test func signingRequirementPinsAppleAnchorIdentifierAndTeam() {
    #expect(signingRequirement.contains("anchor apple generic"))
    #expect(signingRequirement.contains("com.duckduckgo.macos.browser"))
    #expect(signingRequirement.contains("HKE973VLUW"))
  }

  private func checker(for metadata: SignedApplicationMetadata)
    -> DuckDuckGoBuildCompatibilityChecker
  {
    DuckDuckGoBuildCompatibilityChecker(metadataProvider: StubMetadataProvider(metadata: metadata))
  }

  private func metadata(
    bundleIdentifier: String? = DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
    teamIdentifier: String? = DuckDuckGoBuildCompatibilityChecker.teamIdentifier,
    shortVersion: String? = "1.203.0",
    isSandboxed: Bool = false
  ) -> SignedApplicationMetadata {
    SignedApplicationMetadata(
      bundleIdentifier: bundleIdentifier,
      teamIdentifier: teamIdentifier,
      shortVersion: shortVersion,
      isSandboxed: isSandboxed
    )
  }

  private func signingInformation(
    bundleIdentifier: String = DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
    teamIdentifier: String = DuckDuckGoBuildCompatibilityChecker.teamIdentifier,
    shortVersion: String = "1.203.0",
    sandboxValue: Any? = false
  ) -> [String: Any] {
    var entitlements: [String: Any] = [:]
    if let sandboxValue {
      entitlements["com.apple.security.app-sandbox"] = sandboxValue
    }
    return [
      kSecCodeInfoIdentifier as String: bundleIdentifier,
      kSecCodeInfoTeamIdentifier as String: teamIdentifier,
      kSecCodeInfoEntitlementsDict as String: entitlements,
      kSecCodeInfoPList as String: ["CFBundleShortVersionString": shortVersion],
    ]
  }
}

private struct StubMetadataProvider: SignedApplicationMetadataProviding {
  let metadata: SignedApplicationMetadata?

  func metadata(for url: URL) -> SignedApplicationMetadata? {
    metadata
  }
}
