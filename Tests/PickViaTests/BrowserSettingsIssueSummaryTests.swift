import Foundation
import XCTest

@testable import PickVia
@testable import PickViaCore

final class BrowserSettingsIssueSummaryTests: XCTestCase {
  func testAccessOnlyCountsRequiredAndRevokedSupportedInstalledBrowsers() {
    let chrome = issueBrowser(id: "com.google.Chrome", family: .chromium, available: true)
    let firefox = issueBrowser(id: "org.mozilla.firefox", family: .firefox, available: true)
    let scan = BrowserScanResult(
      browsers: [
        DiscoveredBrowser(application: chrome, profiles: [], metadataStatus: .accessRequired),
        DiscoveredBrowser(application: firefox, profiles: [], metadataStatus: .accessRevoked),
      ],
      profileAccessIssues: [
        .accessRequired(bundleIdentifier: chrome.id),
        .accessRevoked(bundleIdentifier: firefox.id),
      ]
    )
    let config = PickViaConfig(
      schemaVersion: 1,
      browsers: [chrome, firefox],
      targets: [
        issueTarget(
          id: "chrome-work", browserID: chrome.id, profileIdentifier: "Work"),
        issueTarget(
          id: "firefox-personal", browserID: firefox.id,
          profileIdentity: "firefox-personal"),
      ]
    )

    let summary = makeBrowserSettingsIssueSummary(
      authoritativeScan: scan,
      metadataOverrides: [:],
      config: config
    )

    XCTAssertEqual(summary.accessIssueBrowserCount, 2)
    XCTAssertEqual(summary.missingEnabledProfileCount, 0)
    XCTAssertEqual(
      summary.segments,
      [BrowserSettingsIssueSegment(kind: .access, count: 2)]
    )
  }

  func testMissingOnlyRecognizesEachProfileSpecificIdentityField() {
    let chrome = issueBrowser(id: "com.google.Chrome", family: .chromium, available: true)
    let firefox = issueBrowser(id: "org.mozilla.firefox", family: .firefox, available: true)
    let scan = BrowserScanResult(
      browsers: [
        DiscoveredBrowser(application: chrome, profiles: [], metadataStatus: .loaded),
        DiscoveredBrowser(application: firefox, profiles: [], metadataStatus: .loaded),
      ],
      profileAccessIssues: []
    )
    let config = PickViaConfig(
      schemaVersion: 1,
      browsers: [chrome, firefox],
      targets: [
        issueTarget(
          id: "identifier", browserID: chrome.id, profileIdentifier: "Profile 1"),
        issueTarget(
          id: "display-name", browserID: chrome.id, profileDisplayName: "Work"),
        issueTarget(
          id: "identity", browserID: firefox.id, profileIdentity: "opaque-identity"),
        issueTarget(
          id: "launch-path", browserID: firefox.id,
          profileLaunchPath: "/Profiles/personal"),
      ]
    )

    let summary = makeBrowserSettingsIssueSummary(
      authoritativeScan: scan,
      metadataOverrides: [:],
      config: config
    )

    XCTAssertEqual(summary.accessIssueBrowserCount, 0)
    XCTAssertEqual(summary.missingEnabledProfileCount, 4)
    XCTAssertEqual(
      summary.segments,
      [BrowserSettingsIssueSegment(kind: .missingProfile, count: 4)]
    )
  }

  func testCombinedSummarySeparatesAccessAndMissingProfilesWithoutDoubleCounting() {
    let chrome = issueBrowser(id: "com.google.Chrome", family: .chromium, available: true)
    let firefox = issueBrowser(id: "org.mozilla.firefox", family: .firefox, available: true)
    let scan = BrowserScanResult(
      browsers: [
        DiscoveredBrowser(application: chrome, profiles: [], metadataStatus: .accessRequired),
        DiscoveredBrowser(application: firefox, profiles: [], metadataStatus: .loaded),
      ],
      profileAccessIssues: [.accessRequired(bundleIdentifier: chrome.id)]
    )
    let config = PickViaConfig(
      schemaVersion: 1,
      browsers: [chrome, firefox],
      targets: [
        issueTarget(
          id: "chrome-work", browserID: chrome.id, profileIdentifier: "Work"),
        issueTarget(
          id: "firefox-personal", browserID: firefox.id,
          profileDisplayName: "Personal"),
      ]
    )

    let summary = makeBrowserSettingsIssueSummary(
      authoritativeScan: scan,
      metadataOverrides: [:],
      config: config
    )

    XCTAssertEqual(summary.accessIssueBrowserCount, 1)
    XCTAssertEqual(summary.missingEnabledProfileCount, 1)
    XCTAssertEqual(
      summary.segments,
      [
        BrowserSettingsIssueSegment(kind: .access, count: 1),
        BrowserSettingsIssueSegment(kind: .missingProfile, count: 1),
      ]
    )
  }

  func testExclusionsIgnoreUnavailableUnsupportedDisabledBrowserLevelAndOrphanTargets() {
    let unavailableChrome = issueBrowser(
      id: "com.google.Chrome", family: .chromium, available: false)
    let unsupported = issueBrowser(
      id: "com.example.Unsupported", family: .chromium, available: true)
    let firefox = issueBrowser(id: "org.mozilla.firefox", family: .firefox, available: true)
    let scan = BrowserScanResult(
      browsers: [
        DiscoveredBrowser(
          application: unavailableChrome, profiles: [], metadataStatus: .accessRevoked),
        DiscoveredBrowser(
          application: unsupported, profiles: [], metadataStatus: .accessRequired),
        DiscoveredBrowser(application: firefox, profiles: [], metadataStatus: .loaded),
      ],
      profileAccessIssues: [
        .accessRevoked(bundleIdentifier: unavailableChrome.id),
        .accessRequired(bundleIdentifier: unsupported.id),
      ]
    )
    let config = PickViaConfig(
      schemaVersion: 1,
      browsers: [unavailableChrome, unsupported, firefox],
      targets: [
        issueTarget(
          id: "unavailable-browser", browserID: unavailableChrome.id,
          profileIdentifier: "Work"),
        issueTarget(
          id: "unsupported-browser", browserID: unsupported.id,
          profileDisplayName: "Work"),
        issueTarget(
          id: "disabled-profile", browserID: firefox.id,
          profileIdentity: "disabled", enabled: false),
        issueTarget(id: "browser-default", browserID: firefox.id),
        issueTarget(
          id: "available-profile", browserID: firefox.id,
          profileIdentifier: "Available", available: true),
        issueTarget(
          id: "orphan-profile", browserID: "org.example.Uninstalled",
          profileLaunchPath: "/Profiles/orphan"),
      ]
    )

    let summary = makeBrowserSettingsIssueSummary(
      authoritativeScan: scan,
      metadataOverrides: [:],
      config: config
    )

    XCTAssertEqual(summary, .init(accessIssueBrowserCount: 0, missingEnabledProfileCount: 0))
    XCTAssertTrue(summary.segments.isEmpty)
    XCTAssertEqual(
      makeBrowserSettingsIssueSummary(
        authoritativeScan: nil,
        metadataOverrides: [firefox.id: .accessRevoked],
        config: config
      ),
      .init(accessIssueBrowserCount: 0, missingEnabledProfileCount: 0)
    )
  }

  func testTargetedMetadataOverrideUpdatesAccessCount() {
    let chrome = issueBrowser(id: "com.google.Chrome", family: .chromium, available: true)
    let scan = BrowserScanResult(
      browsers: [
        DiscoveredBrowser(application: chrome, profiles: [], metadataStatus: .accessRequired)
      ],
      profileAccessIssues: [.accessRequired(bundleIdentifier: chrome.id)]
    )
    let config = PickViaConfig(schemaVersion: 1, browsers: [chrome], targets: [])

    XCTAssertEqual(
      makeBrowserSettingsIssueSummary(
        authoritativeScan: scan, metadataOverrides: [:], config: config
      ).accessIssueBrowserCount,
      1
    )
    XCTAssertEqual(
      makeBrowserSettingsIssueSummary(
        authoritativeScan: scan,
        metadataOverrides: [chrome.id: .loaded],
        config: config
      ).accessIssueBrowserCount,
      0
    )
  }

  func testSegmentsUseApprovedSingularAndPluralCopy() {
    XCTAssertEqual(
      BrowserSettingsIssueSegment(kind: .access, count: 1).text,
      "1 browser needs access"
    )
    XCTAssertEqual(
      BrowserSettingsIssueSegment(kind: .access, count: 2).text,
      "2 browsers need access"
    )
    XCTAssertEqual(
      BrowserSettingsIssueSegment(kind: .missingProfile, count: 1).text,
      "1 profile is missing"
    )
    XCTAssertEqual(
      BrowserSettingsIssueSegment(kind: .missingProfile, count: 3).text,
      "3 profiles are missing"
    )
  }
}

private func issueBrowser(
  id: String,
  family: BrowserFamily,
  available: Bool
) -> BrowserApplication {
  BrowserApplication(
    id: id,
    family: family,
    displayName: id,
    bundleIdentifier: id,
    applicationURL: URL(fileURLWithPath: "/Applications/\(id).app"),
    executableURL: nil,
    isAvailable: available
  )
}

private func issueTarget(
  id: String,
  browserID: String,
  profileIdentifier: String? = nil,
  profileDisplayName: String? = nil,
  profileIdentity: String? = nil,
  profileLaunchPath: String? = nil,
  enabled: Bool = true,
  available: Bool = false
) -> BrowserTarget {
  BrowserTarget(
    id: id,
    browserID: browserID,
    label: profileDisplayName ?? profileIdentifier ?? "Browser Default",
    profileIdentifier: profileIdentifier,
    profileDisplayName: profileDisplayName,
    profileIdentity: profileIdentity,
    profileLaunchPath: profileLaunchPath,
    mode: .normal,
    isEnabled: enabled,
    sortOrder: 0,
    origin: .detected,
    availability: available ? .available : .unavailable
  )
}
