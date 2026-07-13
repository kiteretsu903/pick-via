import Foundation
import Testing

@testable import PickViaCore

struct BrowserCatalogTests {
  @Test func supportedDescriptorsContainExactlyTheApprovedBrowsers() {
    #expect(
      BrowserDescriptor.supported.map(\.bundleIdentifier) == [
        "com.apple.Safari",
        "com.google.Chrome",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "org.mozilla.firefox",
      ])
    #expect(BrowserDescriptor.supported.count == 7)
  }

  @Test func scanReturnsOnlyLocatedSupportedApplicationsInDescriptorOrder() throws {
    let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
    let firefoxURL = URL(fileURLWithPath: "/Applications/Firefox.app", isDirectory: true)
    let localStateURL = URL(
      fileURLWithPath: "/home/Library/Application Support/Google/Chrome/Local State")
    let profilesURL = URL(fileURLWithPath: "/home/Library/Application Support/Firefox/profiles.ini")
    let locator = StubApplicationLocator(applications: [
      "com.google.Chrome": chromeURL,
      "org.mozilla.firefox": firefoxURL,
      "com.example.Unsupported": URL(fileURLWithPath: "/Applications/Unsupported.app"),
    ])
    let fileSystem = DiscoveryFileSystem(files: [
      localStateURL: try fixtureData("chromium-local-state.json"),
      profilesURL: try fixtureData("firefox-profiles.ini"),
    ])
    let catalog = BrowserCatalog(
      applicationLocator: locator,
      fileSystem: fileSystem,
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let discovered = try catalog.scan()

    #expect(
      discovered.map(\.application.bundleIdentifier) == [
        "com.google.Chrome", "org.mozilla.firefox",
      ])
    #expect(discovered[0].profiles.map(\.identifier) == ["Default", "Profile 1"])
    #expect(discovered[1].profiles.map(\.identifier) == ["Personal", "Work"])
    #expect(
      locator.requestedBundleIdentifiers == BrowserDescriptor.supported.map(\.bundleIdentifier))
    #expect(fileSystem.readURLs == [localStateURL, profilesURL])
  }

  @Test func reconcilePreservesUserCustomizationForStableProfileIdentity() {
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [],
      targets: [
        target(
          bundleID: "com.google.Chrome",
          profileID: "Profile 1",
          label: "Client Work",
          enabled: false,
          order: 7
        )
      ]
    )
    let discovered = [chrome(profileID: "Profile 1", profileName: "Work")]

    let result = BrowserCatalog.reconcile(discovered: discovered, with: existing)

    #expect(result.targets.count == 2)
    let normal = result.targets.first { $0.mode == .normal }
    #expect(normal?.label == "Client Work")
    #expect(normal?.isEnabled == false)
    #expect(normal?.sortOrder == 7)
    #expect(normal?.profileDisplayName == "Work")
    #expect(normal?.availability == .available)
    #expect(result.targets.first { $0.mode == .private }?.isEnabled == false)
  }

  @Test func reconcileMarksDisappearedProfileUnavailableWithoutSubstitution() {
    let disappeared = target(
      bundleID: "com.google.Chrome",
      profileID: "Profile 2",
      label: "Old Project",
      enabled: true,
      order: 3
    )
    let existing = PickViaConfig(schemaVersion: 1, browsers: [], targets: [disappeared])

    let result = BrowserCatalog.reconcile(
      discovered: [chrome(profileID: "Profile 1", profileName: "Work")],
      with: existing
    )

    let missing = result.targets.first { $0.id == disappeared.id }
    #expect(missing?.label == "Old Project")
    #expect(missing?.isEnabled == true)
    #expect(missing?.sortOrder == 3)
    #expect(missing?.availability == .unavailable)
    #expect(missing?.profileIdentifier == "Profile 2")
  }

  @Test func reconcileCreatesOnlyNormalSafariTargetAndInitiallyDisablesPrivateTargets() {
    let safari = DiscoveredBrowser(
      application: BrowserApplication(
        id: "com.apple.Safari",
        family: .safari,
        displayName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"),
        executableURL: nil,
        isAvailable: true
      ),
      profiles: []
    )

    let result = BrowserCatalog.reconcile(discovered: [safari], with: .initial)

    #expect(result.targets.count == 1)
    #expect(result.targets[0].mode == .normal)
    #expect(result.targets[0].isEnabled)
  }

  @Test func reconcileKeepsManualTargetAvailableWhenBrowserAndProfileStillExist() throws {
    let manual = manualTarget(profileID: "Profile 1", availability: .unavailable)
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [chrome(profileID: "Profile 1", profileName: "Work").application],
      targets: [manual]
    )

    let result = BrowserCatalog.reconcile(
      discovered: [chrome(profileID: "Profile 1", profileName: "Renamed by Browser")],
      with: existing
    )

    let reconciled = try #require(result.targets.first { $0.id == manual.id })
    #expect(reconciled.label == manual.label)
    #expect(reconciled.profileIdentifier == manual.profileIdentifier)
    #expect(reconciled.profileDisplayName == manual.profileDisplayName)
    #expect(reconciled.mode == manual.mode)
    #expect(reconciled.isEnabled == manual.isEnabled)
    #expect(reconciled.sortOrder == manual.sortOrder)
    #expect(reconciled.origin == .manual)
    #expect(reconciled.availability == .available)
  }

  @Test func reconcileMarksManualTargetUnavailableWhenProfileDisappears() throws {
    let manual = manualTarget(profileID: "Profile 2", availability: .available)
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [chrome(profileID: "Profile 1", profileName: "Work").application],
      targets: [manual]
    )

    let result = BrowserCatalog.reconcile(
      discovered: [chrome(profileID: "Profile 1", profileName: "Work")],
      with: existing
    )

    let reconciled = try #require(result.targets.first { $0.id == manual.id })
    #expect(reconciled.availability == .unavailable)
    #expect(reconciled.profileIdentifier == "Profile 2")
    #expect(reconciled.label == manual.label)
  }
}

private func chrome(profileID: String, profileName: String) -> DiscoveredBrowser {
  DiscoveredBrowser(
    application: BrowserApplication(
      id: "com.google.Chrome",
      family: .chromium,
      displayName: "Google Chrome",
      bundleIdentifier: "com.google.Chrome",
      applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
      executableURL: URL(
        fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
      isAvailable: true
    ),
    profiles: [
      DiscoveredProfile(identifier: profileID, displayName: profileName, directoryURL: nil)
    ]
  )
}

private func target(
  bundleID: String,
  profileID: String,
  label: String,
  enabled: Bool,
  order: Int
) -> BrowserTarget {
  BrowserTarget(
    id: BrowserCatalog.targetID(
      bundleIdentifier: bundleID, profileIdentifier: profileID, mode: .normal),
    browserID: bundleID,
    label: label,
    profileIdentifier: profileID,
    profileDisplayName: profileID,
    mode: .normal,
    isEnabled: enabled,
    sortOrder: order,
    origin: .detected,
    availability: .available
  )
}

private func manualTarget(
  profileID: String,
  availability: BrowserTargetAvailability
) -> BrowserTarget {
  BrowserTarget(
    id: "manual-\(profileID)",
    browserID: "com.google.Chrome",
    label: "Pinned Manual",
    profileIdentifier: profileID,
    profileDisplayName: "Pinned Profile",
    mode: .private,
    isEnabled: false,
    sortOrder: 37,
    origin: .manual,
    availability: availability
  )
}

private final class StubApplicationLocator: ApplicationLocating, @unchecked Sendable {
  private let applications: [String: URL]
  private(set) var requestedBundleIdentifiers: [String] = []

  init(applications: [String: URL]) {
    self.applications = applications
  }

  func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
    requestedBundleIdentifiers.append(bundleIdentifier)
    return applications[bundleIdentifier]
  }
}

private final class DiscoveryFileSystem: FileSystem, @unchecked Sendable {
  private let files: [URL: Data]
  private(set) var readURLs: [URL] = []

  init(files: [URL: Data]) {
    self.files = files
  }

  func fileExists(at url: URL) -> Bool { files[url] != nil }

  func read(from url: URL) throws -> Data {
    readURLs.append(url)
    guard let data = files[url] else { throw CocoaError(.fileNoSuchFile) }
    return data
  }

  func createDirectory(at url: URL) throws {}
  func writeAtomically(_ data: Data, to url: URL) throws {}
  func moveItem(at source: URL, to destination: URL) throws {}
  func replaceItem(at destination: URL, with source: URL) throws {}
}
