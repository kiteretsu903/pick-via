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
    #expect(
      discovered[1].profiles.map(\.identifier) == [
        "/Users/example/Firefox/Profiles/work",
        "/home/Library/Application Support/Firefox/Profiles/personal.default-release",
      ])
    #expect(
      locator.requestedBundleIdentifiers == BrowserDescriptor.supported.map(\.bundleIdentifier))
    #expect(fileSystem.readURLs == [localStateURL, profilesURL])
  }

  @Test func scanIsolatesUnreadableMetadataAndReturnsMixedSuccessWarnings() throws {
    let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
    let firefoxURL = URL(fileURLWithPath: "/Applications/Firefox.app", isDirectory: true)
    let localStateURL = URL(
      fileURLWithPath: "/home/Library/Application Support/Google/Chrome/Local State")
    let profilesURL = URL(fileURLWithPath: "/home/Library/Application Support/Firefox/profiles.ini")
    let fileSystem = DiscoveryFileSystem(
      files: [localStateURL: try fixtureData("chromium-local-state.json")],
      readErrors: [profilesURL: CocoaError(.fileReadNoPermission)]
    )
    let catalog = BrowserCatalog(
      applicationLocator: StubApplicationLocator(applications: [
        "com.google.Chrome": chromeURL,
        "org.mozilla.firefox": firefoxURL,
      ]),
      fileSystem: fileSystem,
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let result = catalog.scanResult()

    #expect(result.browsers.count == 2)
    #expect(result.browsers[0].profiles.count == 2)
    #expect(result.browsers[1].metadataStatus == .unreadable)
    #expect(result.warnings == [.metadataUnreadable(bundleIdentifier: "org.mozilla.firefox")])
  }

  @Test func malformedChromiumMetadataDoesNotAbortFirefoxDiscovery() throws {
    let localStateURL = URL(
      fileURLWithPath: "/home/Library/Application Support/Google/Chrome/Local State")
    let profilesURL = URL(fileURLWithPath: "/home/Library/Application Support/Firefox/profiles.ini")
    let catalog = BrowserCatalog(
      applicationLocator: StubApplicationLocator(applications: [
        "com.google.Chrome": URL(fileURLWithPath: "/Applications/Google Chrome.app"),
        "org.mozilla.firefox": URL(fileURLWithPath: "/Applications/Firefox.app"),
      ]),
      fileSystem: DiscoveryFileSystem(files: [
        localStateURL: Data("not json".utf8),
        profilesURL: try fixtureData("firefox-profiles.ini"),
      ]),
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let result = catalog.scanResult()

    #expect(result.browsers.count == 2)
    #expect(result.browsers[0].metadataStatus == .unreadable)
    #expect(result.browsers[1].profiles.count == 2)
    #expect(result.warnings == [.metadataUnreadable(bundleIdentifier: "com.google.Chrome")])
  }

  @Test func emptyProfileMetadataCreatesUnprofiledNormalAndPrivateFallbacks() {
    let result = BrowserCatalog.reconcile(
      discovered: [chrome(profiles: [], metadataStatus: .absent)],
      with: .initial
    )

    #expect(result.targets.count == 2)
    #expect(result.targets.map(\.profileIdentifier) == [nil, nil])
    #expect(result.targets.map(\.mode) == [.normal, .private])
    #expect(result.targets.map(\.isEnabled) == [true, false])
  }

  @Test func transientUnreadableMetadataPreservesExistingProfileAvailability() throws {
    let existingTarget = target(
      bundleID: "com.google.Chrome",
      profileID: "Profile 1",
      label: "Work",
      enabled: true,
      order: 0
    )
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [chrome(profileID: "Profile 1", profileName: "Work").application],
      targets: [existingTarget]
    )

    let result = BrowserCatalog.reconcile(
      discovered: [chrome(profiles: [], metadataStatus: .unreadable)],
      with: existing
    )

    #expect(result.targets.first { $0.id == existingTarget.id }?.availability == .available)
  }

  @Test func firefoxRenameReconcilesByNormalizedProfilePath() throws {
    let path = URL(fileURLWithPath: "/Users/example/Firefox/Profiles/work", isDirectory: true)
    let original = firefox(profilePath: path, profileName: "Work")
    let initial = BrowserCatalog.reconcile(discovered: [original], with: .initial)
    let normal = try #require(initial.targets.first { $0.mode == .normal })
    let customized = PickViaConfig(
      schemaVersion: 1,
      browsers: initial.browsers,
      targets: initial.targets.map {
        $0.id == normal.id ? copy($0, label: "Client", enabled: false) : $0
      }
    )

    let renamed = BrowserCatalog.reconcile(
      discovered: [firefox(profilePath: path, profileName: "Renamed")],
      with: customized
    )
    let reconciled = try #require(renamed.targets.first { $0.id == normal.id })

    #expect(reconciled.label == "Client")
    #expect(!reconciled.isEnabled)
    #expect(reconciled.profileIdentifier == "Renamed")
    #expect(reconciled.profileIdentity == path.standardizedFileURL.path)
  }

  @Test func legacyFirefoxNameIdentityMigratesWithoutLeavingDuplicateTarget() throws {
    let legacy = BrowserTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: "org.mozilla.firefox",
        profileIdentifier: "Work",
        mode: .normal
      ),
      browserID: "org.mozilla.firefox",
      label: "Client Work",
      profileIdentifier: "Work",
      profileDisplayName: "Work",
      mode: .normal,
      isEnabled: false,
      sortOrder: 4,
      origin: .detected,
      availability: .available
    )
    let path = URL(fileURLWithPath: "/profiles/work", isDirectory: true)
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [firefox(profilePath: path, profileName: "Work").application],
      targets: [legacy]
    )

    let result = BrowserCatalog.reconcile(
      discovered: [firefox(profilePath: path, profileName: "Work")],
      with: existing
    )

    #expect(result.targets.count == 2)
    #expect(result.targets.filter { $0.mode == .normal }.map(\.label) == ["Client Work"])
    #expect(!result.targets.contains { $0.id == legacy.id })
  }

  @Test func firefoxDuplicateNamesRemainDistinctByPathAcrossModes() {
    let browser = firefox(
      profiles: [
        firefoxProfile(path: "/profiles/one", name: "Same"),
        firefoxProfile(path: "/profiles/two", name: "Same"),
      ])

    let result = BrowserCatalog.reconcile(discovered: [browser], with: .initial)

    #expect(result.targets.count == 4)
    #expect(Set(result.targets.map(\.id)).count == 4)
    #expect(Set(result.targets.compactMap(\.profileIdentity)).count == 2)
  }

  @Test func firefoxDisappearanceMarksNormalPrivateAndManualTargetsUnavailable() throws {
    let path = URL(fileURLWithPath: "/profiles/work", isDirectory: true).standardizedFileURL
    let initial = BrowserCatalog.reconcile(
      discovered: [firefox(profilePath: path, profileName: "Work")],
      with: .initial
    )
    let manual = BrowserTarget(
      id: "manual-firefox",
      browserID: "org.mozilla.firefox",
      label: "Pinned",
      profileIdentifier: "Work",
      profileDisplayName: "Work",
      profileIdentity: path.path,
      mode: .normal,
      isEnabled: true,
      sortOrder: 20,
      origin: .manual,
      availability: .available
    )
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: initial.browsers,
      targets: initial.targets + [manual]
    )

    let result = BrowserCatalog.reconcile(
      discovered: [firefox(profiles: [])],
      with: existing
    )

    #expect(
      result.targets.filter { $0.profileIdentity == path.path }.allSatisfy {
        $0.availability == .unavailable
      })
    #expect(result.targets.contains { $0.mode == .normal && $0.origin == .detected })
    #expect(result.targets.contains { $0.mode == .private && $0.origin == .detected })
  }

  @Test func firefoxManualTargetUpdatesLaunchSelectorAfterProfileRename() throws {
    let path = URL(fileURLWithPath: "/profiles/work", isDirectory: true).standardizedFileURL
    let manual = BrowserTarget(
      id: "manual-firefox",
      browserID: "org.mozilla.firefox",
      label: "Pinned",
      profileIdentifier: "Old Name",
      profileDisplayName: "Old Name",
      profileIdentity: path.path,
      mode: .private,
      isEnabled: false,
      sortOrder: 20,
      origin: .manual,
      availability: .available
    )
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [firefox(profilePath: path, profileName: "Old Name").application],
      targets: [manual]
    )

    let result = BrowserCatalog.reconcile(
      discovered: [firefox(profilePath: path, profileName: "New Name")],
      with: existing
    )
    let updated = try #require(result.targets.first { $0.id == manual.id })

    #expect(updated.profileIdentifier == "New Name")
    #expect(updated.profileDisplayName == "New Name")
    #expect(updated.label == "Pinned")
    #expect(!updated.isEnabled)
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
  chrome(
    profiles: [
      DiscoveredProfile(identifier: profileID, displayName: profileName, directoryURL: nil)
    ])
}

private func chrome(
  profiles: [DiscoveredProfile],
  metadataStatus: ProfileMetadataStatus = .loaded
) -> DiscoveredBrowser {
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
    profiles: profiles,
    metadataStatus: metadataStatus
  )
}

private func firefox(profilePath: URL, profileName: String) -> DiscoveredBrowser {
  firefox(profiles: [firefoxProfile(path: profilePath.path, name: profileName)])
}

private func firefox(profiles: [DiscoveredProfile]) -> DiscoveredBrowser {
  DiscoveredBrowser(
    application: BrowserApplication(
      id: "org.mozilla.firefox",
      family: .firefox,
      displayName: "Firefox",
      bundleIdentifier: "org.mozilla.firefox",
      applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
      executableURL: URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox"),
      isAvailable: true
    ),
    profiles: profiles
  )
}

private func firefoxProfile(path: String, name: String) -> DiscoveredProfile {
  let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  return DiscoveredProfile(
    identifier: url.path,
    displayName: name,
    directoryURL: url,
    launchIdentifier: name
  )
}

private func copy(_ target: BrowserTarget, label: String, enabled: Bool) -> BrowserTarget {
  BrowserTarget(
    id: target.id,
    browserID: target.browserID,
    label: label,
    profileIdentifier: target.profileIdentifier,
    profileDisplayName: target.profileDisplayName,
    profileIdentity: target.profileIdentity,
    mode: target.mode,
    isEnabled: enabled,
    sortOrder: target.sortOrder,
    origin: target.origin,
    availability: target.availability
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
  private let readErrors: [URL: any Error]
  private(set) var readURLs: [URL] = []

  init(files: [URL: Data], readErrors: [URL: any Error] = [:]) {
    self.files = files
    self.readErrors = readErrors
  }

  func fileExists(at url: URL) -> Bool { files[url] != nil || readErrors[url] != nil }

  func read(from url: URL) throws -> Data {
    readURLs.append(url)
    if let error = readErrors[url] { throw error }
    guard let data = files[url] else { throw CocoaError(.fileNoSuchFile) }
    return data
  }

  func createDirectory(at url: URL) throws {}
  func writeAtomically(_ data: Data, to url: URL) throws {}
  func moveItem(at source: URL, to destination: URL) throws {}
  func replaceItem(at destination: URL, with source: URL) throws {}
}
