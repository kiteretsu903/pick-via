import Foundation
import PickViaCore
import Testing

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
}

private struct StubMetadataProvider: SignedApplicationMetadataProviding {
  let metadata: SignedApplicationMetadata?

  func metadata(for url: URL) -> SignedApplicationMetadata? {
    metadata
  }
}
