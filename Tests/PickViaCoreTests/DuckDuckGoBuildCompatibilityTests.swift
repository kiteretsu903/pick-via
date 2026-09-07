import Foundation
import Security
import Testing

@testable import PickViaCore

@Suite("DuckDuckGo build compatibility")
struct DuckDuckGoBuildCompatibilityTests {
  private let applicationURL = URL(fileURLWithPath: "/Applications/DuckDuckGo.app")

  @Test func unreadableMetadataDisablesPrivateSupport() {
    let checker = DuckDuckGoBuildCompatibilityChecker(
      metadataProvider: StubMetadataProvider(metadata: nil))
    #expect(checker.compatibility(of: applicationURL) == .unsupported)
  }

  @Test func wrongBrowserIsNotPrivateCompatible() {
    #expect(
      checker(bundleIdentifier: "example.browser").compatibility(of: applicationURL) == .unsupported
    )
  }

  @Test(arguments: ["1.203.0", "1.203.1", "1.203.999"])
  func patchUpdatesUseTheSamePrivatePreferencePolicy(_ version: String) {
    #expect(checker(version: version).compatibility(of: applicationURL) == .fire)
  }

  @Test(arguments: [
    "1.202.99", "1.204.0", "2.203.0", "1.203", "1.203.0-beta", "1.203.-1", "1.203.0.1", "1.203.",
  ])
  func otherReleasesAndMalformedVersionsAreOrdinaryOnly(_ version: String) {
    #expect(checker(version: version).compatibility(of: applicationURL) == .ordinaryOnly)
  }

  @Test func sandboxedAndUnknownBuildsDoNotUseDisposableHome() {
    #expect(checker(sandboxed: true).compatibility(of: applicationURL) == .ordinaryOnly)
    #expect(checker(sandboxed: nil).compatibility(of: applicationURL) == .ordinaryOnly)
    #expect(checker(version: nil).compatibility(of: applicationURL) == .ordinaryOnly)
  }

  @Test func sandboxMetadataDoesNotRequirePublisherOrVersionFields() {
    #expect(duckDuckGoSandboxStatus(from: [:]) == false)
    #expect(
      duckDuckGoSandboxStatus(from: [
        kSecCodeInfoEntitlementsDict as String: ["com.apple.security.app-sandbox": true]
      ]) == true)
    #expect(
      duckDuckGoSandboxStatus(from: [
        kSecCodeInfoEntitlementsDict as String: ["com.apple.security.app-sandbox": "true"]
      ]) == nil)
    #expect(
      duckDuckGoSandboxStatus(from: [kSecCodeInfoEntitlementsDict as String: "invalid"]) == nil)
  }

  private func checker(
    bundleIdentifier: String = DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
    version: String? = "1.203.0", sandboxed: Bool? = false
  ) -> DuckDuckGoBuildCompatibilityChecker {
    DuckDuckGoBuildCompatibilityChecker(
      metadataProvider: StubMetadataProvider(
        metadata:
          DuckDuckGoApplicationMetadata(
            bundleIdentifier: bundleIdentifier, shortVersion: version, isSandboxed: sandboxed)))
  }
}

private struct StubMetadataProvider: DuckDuckGoApplicationMetadataProviding {
  let metadata: DuckDuckGoApplicationMetadata?
  func metadata(for url: URL) -> DuckDuckGoApplicationMetadata? { metadata }
}
