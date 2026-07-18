import Foundation
import XCTest

@testable import PickVia
@testable import PickViaCore

final class BrowserSettingsIssueSummaryTests: XCTestCase {
  func testSummarySeparatesAccessAndMissingProfilesWithoutDoubleCounting() {
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
        issueTarget(browserID: chrome.id, profile: "Work", enabled: true, available: false),
        issueTarget(browserID: firefox.id, profile: "Personal", enabled: true, available: false),
        issueTarget(browserID: firefox.id, profile: "Disabled", enabled: false, available: false),
        issueTarget(browserID: firefox.id, profile: nil, enabled: true, available: true),
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
  browserID: String,
  profile: String?,
  enabled: Bool,
  available: Bool
) -> BrowserTarget {
  BrowserTarget(
    id: "\(browserID)-\(profile ?? "default")-\(enabled)-\(available)",
    browserID: browserID,
    label: profile ?? "Browser Default",
    profileIdentifier: profile,
    profileDisplayName: profile,
    mode: .normal,
    isEnabled: enabled,
    sortOrder: 0,
    origin: .detected,
    availability: available ? .available : .unavailable
  )
}
