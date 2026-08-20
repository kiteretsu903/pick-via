import Foundation
import Testing

@testable import PickViaCore

struct BrowserCatalogTests {
  @Test func supportedDescriptorsContainExactlyTheApprovedBrowsers() {
    #expect(
      BrowserDescriptor.supported.map(\.bundleIdentifier) == [
        "com.apple.Safari",
        "com.duckduckgo.macos.browser",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "org.chromium.Chromium",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "com.vivaldi.Vivaldi",
        "org.mozilla.firefox",
      ])
    #expect(BrowserDescriptor.supported.count == 9)
  }

  @Test func duckDuckGoDescriptorHasNoProfileOrExecutablePaths() throws {
    let descriptor = try #require(
      BrowserDescriptor.descriptor(
        forBundleIdentifier: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier))

    #expect(descriptor.family == .duckDuckGo)
    #expect(descriptor.displayName == "DuckDuckGo")
    #expect(descriptor.profileRoot == nil)
    #expect(descriptor.executableRelativePath == nil)
  }

  @Test func fireCompatibleDuckDuckGoDiscoveryCreatesEnabledNormalAndFireTargets() throws {
    let applicationURL = URL(fileURLWithPath: "/Applications/DuckDuckGo.app", isDirectory: true)
    let access = StubProfileRootAccess()
    let fileSystem = DiscoveryFileSystem(files: [:])
    let catalog = duckDuckGoCatalog(
      applicationURL: applicationURL,
      compatibility: .fire,
      fileSystem: fileSystem,
      profileRootAccess: access
    )

    let browser = try #require(catalog.scan().first)
    let reconciled = BrowserCatalog.reconcile(discovered: [browser], with: .initial)

    #expect(browser.metadataStatus == .notApplicable)
    #expect(browser.profiles.isEmpty)
    #expect(browser.privateModeIsAvailable)
    #expect(access.requestedBundleIdentifiers.isEmpty)
    #expect(fileSystem.readURLs.isEmpty)
    #expect(reconciled.targets.map(\.label) == ["DuckDuckGo", "DuckDuckGo Fire Window"])
    #expect(reconciled.targets.map(\.mode) == [.normal, .private])
    #expect(reconciled.targets.allSatisfy { $0.isEnabled })
    #expect(reconciled.targets.allSatisfy { $0.availability == .available })
  }

  @Test func ordinaryOnlyDuckDuckGoDiscoveryCreatesOnlyNormalTarget() throws {
    let catalog = duckDuckGoCatalog(
      applicationURL: URL(fileURLWithPath: "/Applications/DuckDuckGo.app", isDirectory: true),
      compatibility: .ordinaryOnly
    )

    let browser = try #require(catalog.scan().first)
    let reconciled = BrowserCatalog.reconcile(discovered: [browser], with: .initial)

    #expect(!browser.privateModeIsAvailable)
    #expect(reconciled.targets.map(\.label) == ["DuckDuckGo"])
    #expect(reconciled.targets.map(\.mode) == [.normal])
  }

  @Test func unsupportedDuckDuckGoBuildIsNotDiscovered() throws {
    let catalog = duckDuckGoCatalog(
      applicationURL: URL(fileURLWithPath: "/Applications/DuckDuckGo.app", isDirectory: true),
      compatibility: .unsupported
    )

    #expect(try catalog.scan().isEmpty)
  }

  @Test func ordinaryOnlyDuckDuckGoRescanPreservesButDisablesFireCustomization() throws {
    let fire = duckDuckGoBrowser(privateModeIsAvailable: true)
    let initiallyReconciled = BrowserCatalog.reconcile(discovered: [fire], with: .initial)
    let fireID = BrowserCatalog.targetID(
      bundleIdentifier: fire.application.bundleIdentifier,
      profileIdentifier: nil,
      mode: .private
    )
    let customized = initiallyReconciled.targets.map { target in
      target.id == fireID
        ? copy(target, label: "My Fire", enabled: false, sortOrder: 23)
        : target
    }
    let ordinaryOnly = duckDuckGoBrowser(privateModeIsAvailable: false)

    let result = BrowserCatalog.reconcile(
      discovered: [ordinaryOnly],
      with: PickViaConfig(
        schemaVersion: initiallyReconciled.schemaVersion,
        browsers: initiallyReconciled.browsers,
        targets: customized
      )
    )
    let persistedFire = try #require(result.targets.first { $0.id == fireID })

    #expect(persistedFire.label == "My Fire")
    #expect(!persistedFire.isEnabled)
    #expect(persistedFire.sortOrder == 23)
    #expect(persistedFire.mode == .private)
    #expect(persistedFire.availability == .unavailable)
    #expect(!result.targets.contains { $0.mode == .normal && $0.label == "My Fire" })
  }

  @Test func fireCompatibleDuckDuckGoRescanReenablesCanonicalTargetWithoutDuplication() throws {
    let ordinaryOnly = duckDuckGoBrowser(privateModeIsAvailable: false)
    let fire = duckDuckGoBrowser(privateModeIsAvailable: true)
    let fireID = BrowserCatalog.targetID(
      bundleIdentifier: fire.application.bundleIdentifier,
      profileIdentifier: nil,
      mode: .private
    )
    let persistedFire = BrowserTarget(
      id: fireID,
      browserID: fire.application.id,
      label: "My Fire",
      profileIdentifier: nil,
      profileDisplayName: nil,
      mode: .private,
      isEnabled: false,
      sortOrder: 23,
      origin: .detected,
      availability: .unavailable
    )
    let unavailable = BrowserCatalog.reconcile(
      discovered: [ordinaryOnly],
      with: PickViaConfig(schemaVersion: 1, browsers: [fire.application], targets: [persistedFire])
    )

    let result = BrowserCatalog.reconcile(discovered: [fire], with: unavailable)
    let restored = try #require(result.targets.first { $0.id == fireID })

    #expect(result.targets.filter { $0.id == fireID }.count == 1)
    #expect(restored.label == "My Fire")
    #expect(!restored.isEnabled)
    #expect(restored.sortOrder == 23)
    #expect(restored.availability == .available)
  }

  @Test func duckDuckGoRescanNeverMakesPersistedProfileTargetAvailable() throws {
    let browser = duckDuckGoBrowser(privateModeIsAvailable: true)
    let profileTarget = catalogTarget(
      browser: browser.application,
      label: "Stale Profile",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Profile 1",
      profileIdentity: "Profile 1",
      mode: .normal,
      isEnabled: true,
      sortOrder: 10
    )

    let result = BrowserCatalog.reconcile(
      discovered: [browser],
      with: PickViaConfig(
        schemaVersion: 1, browsers: [browser.application], targets: [profileTarget])
    )

    #expect(result.targets.first { $0.id == profileTarget.id }?.availability == .unavailable)
  }

  @Test func duckDuckGoCanonicalIDCollisionPreservesProfileEvidenceAsUnavailable() throws {
    let browser = duckDuckGoBrowser(privateModeIsAvailable: true)
    let collidingID = BrowserCatalog.targetID(
      bundleIdentifier: browser.application.bundleIdentifier,
      profileIdentifier: nil,
      mode: .normal
    )
    let collidingTarget = catalogTarget(
      id: collidingID,
      browser: browser.application,
      label: "Colliding Profile",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Profile 1",
      profileIdentity: "Profile 1",
      mode: .normal,
      isEnabled: false,
      sortOrder: 7,
      availability: .unavailable
    )

    let result = BrowserCatalog.reconcile(
      discovered: [browser],
      with: PickViaConfig(
        schemaVersion: 1,
        browsers: [browser.application],
        targets: [collidingTarget]
      )
    )
    let persistedCollision = try #require(result.targets.first { $0.id == collidingID })
    let privateID = BrowserCatalog.targetID(
      bundleIdentifier: browser.application.bundleIdentifier,
      profileIdentifier: nil,
      mode: .private
    )

    #expect(result.targets.filter { $0.id == collidingID }.count == 1)
    #expect(persistedCollision.availability == .unavailable)
    #expect(persistedCollision.profileIdentifier == "Profile 1")
    #expect(persistedCollision.profileDisplayName == "Profile 1")
    #expect(persistedCollision.profileIdentity == "Profile 1")
    #expect(result.targets.first { $0.id == privateID }?.availability == .available)
  }

  @Test func chromeBetaDescriptorUsesCanonicalMacMetadata() throws {
    let descriptor = try #require(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome.beta"))

    #expect(descriptor.family == .chromium)
    #expect(descriptor.displayName == "Google Chrome Beta")
    #expect(descriptor.profileRoot == "Library/Application Support/Google/Chrome Beta")
    #expect(descriptor.executableRelativePath == "Contents/MacOS/Google Chrome Beta")
  }

  @Test func chromeBetaDiscoveryReadsItsOwnLocalState() throws {
    let betaDescriptor = try #require(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome.beta"))
    let betaApplicationURL = URL(
      fileURLWithPath: "/Applications/Google Chrome Beta.app", isDirectory: true)
    let betaLocalStateURL = URL(
      fileURLWithPath: "/home/Library/Application Support/Google/Chrome Beta/Local State")
    let locator = StubApplicationLocator(applications: [
      "com.google.Chrome.beta": betaApplicationURL
    ])
    let fileSystem = DiscoveryFileSystem(files: [
      betaLocalStateURL: try fixtureData("chromium-local-state.json")
    ])
    let catalog = BrowserCatalog(
      descriptors: [betaDescriptor],
      applicationLocator: locator,
      fileSystem: fileSystem,
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let browser = try #require(catalog.scan().first)

    #expect(browser.application.bundleIdentifier == "com.google.Chrome.beta")
    #expect(browser.application.displayName == "Google Chrome Beta")
    #expect(browser.profiles.map(\.identifier) == ["Default", "Profile 1"])
    #expect(locator.requestedBundleIdentifiers == ["com.google.Chrome.beta"])
    #expect(fileSystem.readURLs == [betaLocalStateURL])
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
      Set(discovered[1].profiles.map(\.identifier)) == [
        FirefoxProfileIdentity.identifier(
          for: URL(fileURLWithPath: "/Users/example/Firefox/Profiles/work", isDirectory: true)
        ),
        FirefoxProfileIdentity.identifier(
          for: URL(
            fileURLWithPath:
              "/home/Library/Application Support/Firefox/Profiles/personal.default-release",
            isDirectory: true
          )
        ),
      ])
    #expect(
      locator.requestedBundleIdentifiers == BrowserDescriptor.supported.map(\.bundleIdentifier))
    #expect(fileSystem.readURLs == [localStateURL, profilesURL])
  }

  @Test func permissionDeniedConventionalRootRequiresAccessWithoutBlockingOtherBrowsers() throws {
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
    #expect(result.browsers[1].metadataStatus == .accessRequired)
    #expect(
      result.profileAccessIssues == [
        .accessRequired(bundleIdentifier: "org.mozilla.firefox")
      ])
    #expect(result.warnings == result.profileAccessIssues)
  }

  @Test func conventionalMarkerIOFailureIsDamagedAndNeverRequestsAccess() {
    let marker = URL(
      fileURLWithPath: "/home/Library/Application Support/Firefox/profiles.ini")
    let catalog = BrowserCatalog(
      descriptors: [firefoxDescriptor],
      applicationLocator: StubApplicationLocator(applications: [
        "org.mozilla.firefox": URL(fileURLWithPath: "/Applications/Firefox.app")
      ]),
      fileSystem: DiscoveryFileSystem(
        files: [:],
        readErrors: [marker: POSIXError(.EIO)]
      ),
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let result = catalog.scanResult()

    #expect(result.browsers.first?.metadataStatus == .metadataDamaged)
    #expect(
      result.profileAccessIssues == [
        .metadataDamaged(bundleIdentifier: "org.mozilla.firefox")
      ])
    #expect(
      !result.profileAccessIssues.contains {
        if case .accessRequired = $0 { return true }
        if case .accessRevoked = $0 { return true }
        return false
      })
  }

  @Test func grantedMarkerTypeFailureIsDamagedAndNeverRequestsReplacement() {
    let grantedRoot = URL(fileURLWithPath: "/Granted/Firefox", isDirectory: true)
    let marker = grantedRoot.appending(path: "profiles.ini")
    let access = StubProfileRootAccess(grantedRoots: ["org.mozilla.firefox": grantedRoot])
    let catalog = BrowserCatalog(
      descriptors: [firefoxDescriptor],
      applicationLocator: StubApplicationLocator(applications: [
        "org.mozilla.firefox": URL(fileURLWithPath: "/Applications/Firefox.app")
      ]),
      fileSystem: DiscoveryFileSystem(
        files: [:],
        readErrors: [marker: CocoaError(.fileReadInapplicableStringEncoding)]
      ),
      profileRootAccess: access,
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let result = catalog.scanResult()

    #expect(result.browsers.first?.metadataStatus == .metadataDamaged)
    #expect(
      result.profileAccessIssues == [
        .metadataDamaged(bundleIdentifier: "org.mozilla.firefox")
      ])
    #expect(access.endedBundleIdentifiers == ["org.mozilla.firefox"])
  }

  @Test func malformedFirefoxNumericProfileSectionIsMetadataDamaged() {
    let marker = URL(
      fileURLWithPath: "/home/Library/Application Support/Firefox/profiles.ini")
    let catalog = BrowserCatalog(
      descriptors: [firefoxDescriptor],
      applicationLocator: StubApplicationLocator(applications: [
        "org.mozilla.firefox": URL(fileURLWithPath: "/Applications/Firefox.app")
      ]),
      fileSystem: DiscoveryFileSystem(files: [
        marker: Data(
          """
          [Profile0]
          Name=Duplicate Name
          IsRelative=1
          """.utf8)
      ]),
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let result = catalog.scanResult()

    #expect(result.browsers.first?.metadataStatus == .metadataDamaged)
    #expect(result.browsers.first?.profiles.isEmpty == true)
    #expect(
      result.profileAccessIssues == [
        .metadataDamaged(bundleIdentifier: "org.mozilla.firefox")
      ])
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
    #expect(result.browsers[0].metadataStatus == .metadataDamaged)
    #expect(result.browsers[1].profiles.count == 2)
    #expect(
      result.profileAccessIssues == [
        .metadataDamaged(bundleIdentifier: "com.google.Chrome")
      ])
  }

  @Test func missingConventionalMarkerIsMetadataAbsent() {
    let catalog = BrowserCatalog(
      descriptors: [chromeDescriptor],
      applicationLocator: StubApplicationLocator(applications: [
        "com.google.Chrome": URL(fileURLWithPath: "/Applications/Google Chrome.app")
      ]),
      fileSystem: DiscoveryFileSystem(
        files: [:],
        readErrors: [
          URL(
            fileURLWithPath:
              "/home/Library/Application Support/Google/Chrome/Local State"
          ): CocoaError(.fileReadNoSuchFile)
        ]
      ),
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let result = catalog.scanResult()

    #expect(result.browsers.first?.metadataStatus == .metadataAbsent)
    #expect(result.profileAccessIssues.isEmpty)
  }

  @Test func revokedSavedGrantDoesNotRetryConventionalPath() {
    let conventionalMarker = URL(
      fileURLWithPath: "/home/Library/Application Support/Google/Chrome/Local State")
    let fileSystem = DiscoveryFileSystem(files: [conventionalMarker: Data("{}".utf8)])
    let access = StubProfileRootAccess(states: ["com.google.Chrome": .revoked])
    let catalog = BrowserCatalog(
      descriptors: [chromeDescriptor],
      applicationLocator: StubApplicationLocator(applications: [
        "com.google.Chrome": URL(fileURLWithPath: "/Applications/Google Chrome.app")
      ]),
      fileSystem: fileSystem,
      profileRootAccess: access,
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let result = catalog.scanResult()

    #expect(result.browsers.first?.metadataStatus == .accessRevoked)
    #expect(
      result.profileAccessIssues == [
        .accessRevoked(bundleIdentifier: "com.google.Chrome")
      ])
    #expect(fileSystem.readURLs.isEmpty)
  }

  @Test func resolvedSavedGrantUsesGrantedRootAndEndsLease() throws {
    let grantedRoot = URL(fileURLWithPath: "/Granted/Chrome", isDirectory: true)
    let marker = grantedRoot.appending(path: "Local State")
    let fileSystem = DiscoveryFileSystem(files: [
      marker: try fixtureData("chromium-local-state.json")
    ])
    let access = StubProfileRootAccess(grantedRoots: ["com.google.Chrome": grantedRoot])
    let catalog = BrowserCatalog(
      descriptors: [chromeDescriptor],
      applicationLocator: StubApplicationLocator(applications: [
        "com.google.Chrome": URL(fileURLWithPath: "/Applications/Google Chrome.app")
      ]),
      fileSystem: fileSystem,
      profileRootAccess: access,
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let result = catalog.scanResult()

    #expect(result.browsers.first?.metadataStatus == .loaded)
    #expect(result.browsers.first?.profiles.map(\.identifier) == ["Default", "Profile 1"])
    #expect(fileSystem.readURLs == [marker])
    #expect(access.endedBundleIdentifiers == ["com.google.Chrome"])
  }

  @Test func grantedRootWithoutRequiredMarkerIsAccessRevoked() {
    let grantedRoot = URL(fileURLWithPath: "/Moved/Chrome", isDirectory: true)
    let access = StubProfileRootAccess(grantedRoots: ["com.google.Chrome": grantedRoot])
    let catalog = BrowserCatalog(
      descriptors: [chromeDescriptor],
      applicationLocator: StubApplicationLocator(applications: [
        "com.google.Chrome": URL(fileURLWithPath: "/Applications/Google Chrome.app")
      ]),
      fileSystem: DiscoveryFileSystem(files: [:]),
      profileRootAccess: access,
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let result = catalog.scanResult()

    #expect(result.browsers.first?.metadataStatus == .accessRevoked)
    #expect(access.endedBundleIdentifiers == ["com.google.Chrome"])
  }

  @Test func targetedScanInspectsOnlyMatchingDescriptor() throws {
    let chromeMarker = URL(
      fileURLWithPath: "/home/Library/Application Support/Google/Chrome/Local State")
    let firefoxMarker = URL(
      fileURLWithPath: "/home/Library/Application Support/Firefox/profiles.ini")
    let locator = StubApplicationLocator(applications: [
      "com.google.Chrome": URL(fileURLWithPath: "/Applications/Google Chrome.app"),
      "org.mozilla.firefox": URL(fileURLWithPath: "/Applications/Firefox.app"),
    ])
    let fileSystem = DiscoveryFileSystem(files: [
      chromeMarker: try fixtureData("chromium-local-state.json"),
      firefoxMarker: try fixtureData("firefox-profiles.ini"),
    ])
    let access = StubProfileRootAccess()
    let catalog = BrowserCatalog(
      descriptors: [chromeDescriptor, firefoxDescriptor],
      applicationLocator: locator,
      fileSystem: fileSystem,
      profileRootAccess: access,
      homeDirectory: URL(fileURLWithPath: "/home", isDirectory: true)
    )

    let result = catalog.scanResult(for: "com.google.Chrome")

    #expect(result?.application.bundleIdentifier == "com.google.Chrome")
    #expect(locator.requestedBundleIdentifiers == ["com.google.Chrome"])
    #expect(access.requestedBundleIdentifiers == ["com.google.Chrome"])
    #expect(fileSystem.readURLs == [chromeMarker])
  }

  @Test func emptyProfileMetadataCreatesUnprofiledNormalAndPrivateFallbacks() {
    let result = BrowserCatalog.reconcile(
      discovered: [chrome(profiles: [], metadataStatus: .metadataAbsent)],
      with: .initial
    )

    #expect(result.targets.count == 2)
    #expect(result.targets.map(\.profileIdentifier) == [nil, nil])
    #expect(result.targets.map(\.mode) == [.normal, .private])
    #expect(result.targets.map(\.isEnabled) == [true, true])
  }

  @Test func reconcileRetainsMailCapabilityAndAppendsMailTargetsUnchanged() throws {
    let discovered = chrome(profiles: [], metadataStatus: .metadataAbsent)
    let combinedApplication = RoutedApplication(
      id: discovered.application.id,
      displayName: discovered.application.displayName,
      bundleIdentifier: discovered.application.bundleIdentifier,
      capabilities: [
        .browser(family: .chromium, isAvailable: false),
        .mail(isAvailable: true),
      ],
      applicationURL: discovered.application.applicationURL,
      browserExecutableURL: discovered.application.browserExecutableURL
    )
    let mailTarget = RouteTarget(
      id: RouteTarget.mailID(bundleIdentifier: combinedApplication.bundleIdentifier),
      applicationID: combinedApplication.id,
      label: "Google Chrome Mail",
      isEnabled: false,
      sortOrder: 42,
      origin: .detected,
      availability: .unavailable,
      capability: .mail
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [combinedApplication],
      targets: [mailTarget]
    )

    let result = BrowserCatalog.reconcile(discovered: [discovered], with: config)

    let application = try #require(result.applications.first)
    #expect(application.browserFamily == .chromium)
    #expect(application.isAvailable(for: .web))
    #expect(application.supports(.mail))
    #expect(application.isAvailable(for: .mail))
    #expect(result.targets.last == mailTarget)
    #expect(result.targets.last?.sortOrder == 42)
    #expect(result.targets.dropLast().allSatisfy { $0.routeKind == .web })
  }

  @Test func runtimeSanitizedFallbackRetainsMailTargetsUnchanged() {
    let application = RoutedApplication(
      id: "org.mozilla.firefox",
      displayName: "Firefox",
      bundleIdentifier: "org.mozilla.firefox",
      capabilities: [
        .browser(family: .firefox, isAvailable: true),
        .mail(isAvailable: true),
      ],
      applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app")
    )
    let mailTarget = RouteTarget(
      id: RouteTarget.mailID(bundleIdentifier: application.bundleIdentifier),
      applicationID: application.id,
      label: "Firefox Mail",
      isEnabled: true,
      sortOrder: 9,
      origin: .detected,
      availability: .available,
      capability: .mail
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [application],
      targets: [mailTarget]
    )

    let result = BrowserCatalog.runtimeSanitizedFallback(config)

    #expect(result.applications == config.applications)
    #expect(result.targets == [mailTarget])
  }

  @Test func detectedTargetDefaultsEnableOnlyBrowserPrivateAndAllNormalTargets() {
    let discovered = chrome(profiles: [
      DiscoveredProfile(
        identifier: "Default",
        displayName: "Personal",
        directoryURL: nil,
        isDefault: true
      ),
      DiscoveredProfile(identifier: "Profile 1", displayName: "Work", directoryURL: nil),
    ])

    let result = BrowserCatalog.reconcile(discovered: [discovered], with: .initial)
    let values = result.targets.map { target in
      (target.profileIdentity == nil, target.mode, target.isEnabled)
    }

    #expect(values.count == 4)
    #expect(values[0].0 && values[0].1 == .normal && values[0].2)
    #expect(values[1].0 && values[1].1 == .private && values[1].2)
    #expect(!values[2].0 && values[2].1 == .normal && values[2].2)
    #expect(!values[3].0 && values[3].1 == .private && !values[3].2)
  }

  @Test func damagedMetadataPreservesExistingProfileAvailability() throws {
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
      discovered: [chrome(profiles: [], metadataStatus: .metadataDamaged)],
      with: existing
    )

    #expect(result.targets.first { $0.id == existingTarget.id }?.availability == .available)
    #expect(result.targets.contains { $0.profileIdentifier == nil && $0.mode == .normal })
    #expect(result.targets.contains { $0.profileIdentifier == nil && $0.mode == .private })
  }

  @Test func chromiumAlwaysCreatesBrowserDefaultAndAbsorbsCanonicalDirectory() {
    let discovered = chrome(profiles: [
      DiscoveredProfile(
        identifier: "Default",
        displayName: "Personal",
        directoryURL: nil,
        isDefault: true
      ),
      DiscoveredProfile(identifier: "Profile 1", displayName: "Work", directoryURL: nil),
    ])

    let result = BrowserCatalog.reconcile(discovered: [discovered], with: .initial)
    let chromeTargets = result.targets.filter { $0.browserID == discovered.application.id }

    #expect(chromeTargets.map(\.profileIdentifier) == [nil, nil, "Profile 1", "Profile 1"])
    #expect(chromeTargets.filter { $0.profileIdentity == "Default" }.isEmpty)
    #expect(chromeTargets[0].mode == .normal)
    #expect(chromeTargets[0].isEnabled)
    #expect(chromeTargets[1].mode == .private)
    #expect(chromeTargets[1].isEnabled)
  }

  @Test func firefoxAbsorbsDefaultOnlyWhenTheFlagIsUnique() {
    let root = URL(fileURLWithPath: "/Users/example/Firefox/Profiles", isDirectory: true)
    let first = DiscoveredProfile(
      identifier: "first", displayName: "First", directoryURL: root.appending(path: "first"),
      launchIdentifier: "First", isDefault: true)
    let second = DiscoveredProfile(
      identifier: "second", displayName: "Second", directoryURL: root.appending(path: "second"),
      launchIdentifier: "Second", isDefault: true)

    let unique = BrowserCatalog.reconcile(
      discovered: [
        firefox(profiles: [
          first,
          DiscoveredProfile(
            identifier: "work", displayName: "Work", directoryURL: root.appending(path: "work"),
            launchIdentifier: "Work"),
        ])
      ],
      with: .initial
    )
    #expect(unique.targets.filter { $0.profileIdentity == "first" }.isEmpty)

    let ambiguous = BrowserCatalog.reconcile(
      discovered: [firefox(profiles: [first, second])],
      with: .initial
    )
    #expect(ambiguous.targets.contains { $0.profileIdentity == "first" })
    #expect(ambiguous.targets.contains { $0.profileIdentity == "second" })
    #expect(
      ambiguous.targets.contains {
        $0.profileIdentifier == nil && $0.profileIdentity == nil && $0.mode == .normal
      })
  }

  @Test func damagedOrInaccessibleMetadataStillCreatesBrowserDefaultPair() {
    for status in [
      ProfileMetadataStatus.metadataDamaged,
      .accessRequired,
      .accessRevoked,
    ] {
      let browser = chrome(profiles: [], metadataStatus: status)
      let result = BrowserCatalog.reconcile(discovered: [browser], with: .initial)
      #expect(result.targets.map(\.profileIdentifier) == [nil, nil])
      #expect(result.targets.allSatisfy { $0.availability == .available })
    }
  }

  @Test func protectedMetadataAddsFallbackAndPreservesCustomizedProfileAsUnavailable() throws {
    for status in [ProfileMetadataStatus.accessRequired, .accessRevoked] {
      let existingTarget = target(
        bundleID: "com.google.Chrome",
        profileID: "Profile 1",
        label: "Client Work",
        enabled: false,
        order: 7
      )
      let manual = unprofiledManualTarget(browserID: "com.google.Chrome")
      let existing = PickViaConfig(
        schemaVersion: 1,
        browsers: [chrome(profileID: "Profile 1", profileName: "Work").application],
        targets: [existingTarget, manual]
      )

      let result = BrowserCatalog.reconcile(
        discovered: [
          chrome(
            profiles: [
              DiscoveredProfile(
                identifier: "stale-profile",
                displayName: "Stale Profile",
                directoryURL: nil
              )
            ],
            metadataStatus: status
          )
        ],
        with: existing
      )

      let preserved = try #require(result.targets.first { $0.id == existingTarget.id })
      #expect(preserved.label == "Client Work")
      #expect(preserved.availability == .unavailable)
      #expect(preserved.isEnabled == false)
      #expect(preserved.sortOrder == 7)
      #expect(result.targets.contains { $0.profileIdentity == nil && $0.mode == .normal })
      #expect(result.targets.contains { $0.profileIdentity == nil && $0.mode == .private })
      let manualDefault = try #require(result.targets.first { $0.id == manual.id })
      #expect(manualDefault.label == manual.label)
      #expect(manualDefault.profileIdentifier == nil)
      #expect(manualDefault.profileDisplayName == nil)
      #expect(manualDefault.profileIdentity == nil)
      #expect(manualDefault.profileLaunchPath == nil)
      #expect(manualDefault.availability == .available)
    }
  }

  @Test func loadedScanRestoresStableProfileAfterAccessReturnsWithoutDuplicate() throws {
    let original = BrowserCatalog.reconcile(
      discovered: [chrome(profileID: "Profile 1", profileName: "Work")],
      with: .initial
    )
    let protected = BrowserCatalog.reconcile(
      discovered: [chrome(profiles: [], metadataStatus: .accessRequired)],
      with: original
    )

    let restored = BrowserCatalog.reconcile(
      discovered: [chrome(profileID: "Profile 1", profileName: "Renamed")],
      with: protected
    )

    let profileTargets = restored.targets.filter { $0.profileIdentity == "Profile 1" }
    #expect(profileTargets.count == 2)
    #expect(profileTargets.allSatisfy { $0.availability == .available })
    #expect(Set(restored.targets.map(\.id)).count == restored.targets.count)
  }

  @Test func firefoxRenameReconcilesByNormalizedProfilePath() throws {
    let path = URL(fileURLWithPath: "/Users/example/Firefox/Profiles/work", isDirectory: true)
    let original = firefox(profilePath: path, profileName: "Work")
    let initial = BrowserCatalog.reconcile(discovered: [original], with: .initial)
    let normal = try #require(
      initial.targets.first {
        $0.profileIdentity == FirefoxProfileIdentity.identifier(for: path) && $0.mode == .normal
      })
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
    #expect(reconciled.profileIdentity == FirefoxProfileIdentity.identifier(for: path))
    #expect(reconciled.profileLaunchPath == path.standardizedFileURL.path)
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

    #expect(result.targets.count == 4)
    #expect(
      result.targets.filter { $0.profileIdentity != nil && $0.mode == .normal }.map(\.label)
        == ["Client Work"])
    #expect(!result.targets.contains { $0.id == legacy.id })
  }

  @Test func nameOnlyLegacyFirefoxTargetWaitsSafelyThenMigratesAfterUniqueDiscovery() throws {
    let legacy = BrowserTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: "org.mozilla.firefox",
        profileIdentifier: "Same Name",
        mode: .normal
      ),
      browserID: "org.mozilla.firefox",
      label: "Client Work",
      profileIdentifier: "Same Name",
      profileDisplayName: "Same Name",
      profileIdentity: nil,
      mode: .normal,
      isEnabled: false,
      sortOrder: 7,
      origin: .detected,
      availability: .available
    )
    let application = firefox(profiles: []).application
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [application],
      targets: [legacy]
    )

    for status in [ProfileMetadataStatus.metadataDamaged, .accessRequired, .accessRevoked] {
      let waiting = BrowserCatalog.reconcile(
        discovered: [firefox(profiles: [], metadataStatus: status)],
        with: existing
      )
      let preserved = try #require(waiting.targets.first { $0.id == legacy.id })
      let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
      defer { try? FileManager.default.removeItem(at: directory) }

      #expect(preserved.availability == .unavailable)
      #expect(preserved.profileIdentity == nil)
      #expect(preserved.profileLaunchPath == nil)
      #expect(preserved.label == "Client Work")
      try JSONConfigStore(directory: directory).save(waiting)
      let document = try #require(
        String(
          data: Data(contentsOf: directory.appending(path: "PickViaConfig.json")),
          encoding: .utf8
        )
      )
      #expect(!document.contains("/Users"))
      #expect(!document.contains("private-user"))
    }

    let ambiguous = BrowserCatalog.reconcile(
      discovered: [
        firefox(
          profiles: [
            firefoxProfile(path: "/profiles/one", name: "Same Name"),
            firefoxProfile(path: "/profiles/two", name: "Same Name"),
          ]
        )
      ],
      with: existing
    )
    let stillWaiting = try #require(ambiguous.targets.first { $0.id == legacy.id })
    #expect(stillWaiting.availability == .unavailable)
    #expect(stillWaiting.profileIdentity == nil)
    #expect(stillWaiting.profileLaunchPath == nil)

    let path = URL(fileURLWithPath: "/profiles/unique", isDirectory: true).standardizedFileURL
    let migrated = BrowserCatalog.reconcile(
      discovered: [firefox(profilePath: path, profileName: "Same Name")],
      with: ambiguous
    )
    let canonical = try #require(
      migrated.targets.first {
        $0.profileIdentity == FirefoxProfileIdentity.identifier(for: path) && $0.mode == .normal
      })
    #expect(canonical.id != legacy.id)
    #expect(canonical.profileIdentity == FirefoxProfileIdentity.identifier(for: path))
    #expect(canonical.profileLaunchPath == path.path)
    #expect(canonical.availability == .available)
    #expect(canonical.label == "Client Work")
    #expect(canonical.isEnabled == false)
    #expect(canonical.sortOrder == 7)
    #expect(!migrated.targets.contains { $0.id == legacy.id })
  }

  @Test func firefoxDuplicateNamesRemainDistinctByPathAcrossModes() {
    let browser = firefox(
      profiles: [
        firefoxProfile(path: "/profiles/one", name: "Same"),
        firefoxProfile(path: "/profiles/two", name: "Same"),
      ])

    let result = BrowserCatalog.reconcile(discovered: [browser], with: .initial)

    #expect(result.targets.count == 6)
    #expect(Set(result.targets.map(\.id)).count == 6)
    #expect(Set(result.targets.compactMap(\.profileIdentity)).count == 2)
  }

  @Test func duplicateFirefoxPathMetadataProducesOneTargetPair() {
    let browser = firefox(
      profiles: [
        firefoxProfile(path: "/profiles/same", name: "First Name"),
        firefoxProfile(path: "/profiles/same", name: "Duplicate Name"),
      ])

    let result = BrowserCatalog.reconcile(discovered: [browser], with: .initial)

    #expect(result.targets.count == 4)
    #expect(Set(result.targets.map(\.id)).count == 4)
    #expect(
      Set(result.targets.compactMap(\.profileIdentity))
        == [FirefoxProfileIdentity.identifier(for: URL(fileURLWithPath: "/profiles/same"))]
    )
  }

  @Test func duplicateFirefoxPathMetadataPreservesCanonicalDefaultMarker() {
    let path = URL(fileURLWithPath: "/profiles/same", isDirectory: true).standardizedFileURL
    let identity = FirefoxProfileIdentity.identifier(for: path)
    let browser = firefox(
      profiles: [
        DiscoveredProfile(
          identifier: identity,
          displayName: "A Compatibility Entry",
          directoryURL: path,
          launchIdentifier: "A Compatibility Entry"
        ),
        DiscoveredProfile(
          identifier: identity,
          displayName: "Z Install Default",
          directoryURL: path,
          launchIdentifier: "Z Install Default",
          isDefault: true
        ),
      ])

    let result = BrowserCatalog.reconcile(discovered: [browser], with: .initial)

    #expect(result.targets.count == 2)
    #expect(result.targets.allSatisfy { $0.profileIdentity == nil })
  }

  @Test func duplicateFirefoxNamesDoNotReuseLegacyDetectedCustomization() {
    let legacy = BrowserTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: "org.mozilla.firefox",
        profileIdentifier: "Same",
        mode: .normal
      ),
      browserID: "org.mozilla.firefox",
      label: "Customized Legacy",
      profileIdentifier: "Same",
      profileDisplayName: "Same",
      mode: .normal,
      isEnabled: false,
      sortOrder: 8,
      origin: .detected,
      availability: .available
    )
    let browser = firefox(
      profiles: [
        firefoxProfile(path: "/profiles/one", name: "Same"),
        firefoxProfile(path: "/profiles/two", name: "Same"),
      ])
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [legacy]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: existing)

    #expect(
      result.targets.filter { $0.profileIdentity != nil }.allSatisfy {
        $0.label != "Customized Legacy"
      })
  }

  @Test func uniquelyNamedLegacyManualFirefoxTargetMigratesToDurablePath() throws {
    let path = URL(fileURLWithPath: "/profiles/unique", isDirectory: true).standardizedFileURL
    let manual = BrowserTarget(
      id: "manual-firefox-legacy",
      browserID: "org.mozilla.firefox",
      label: "Pinned",
      profileIdentifier: "Unique Name",
      profileDisplayName: "Unique Name",
      mode: .private,
      isEnabled: true,
      sortOrder: 12,
      origin: .manual,
      availability: .available
    )
    let browser = firefox(profilePath: path, profileName: "Unique Name")
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [manual]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: existing)
    let migrated = try #require(result.targets.first { $0.id == manual.id })

    #expect(migrated.profileIdentifier == "Unique Name")
    #expect(migrated.profileIdentity == FirefoxProfileIdentity.identifier(for: path))
    #expect(migrated.profileLaunchPath == path.path)
    #expect(migrated.availability == .available)
  }

  @Test func duplicateMetadataForOnePathStillMigratesUniqueLegacyManualTarget() throws {
    let path = URL(fileURLWithPath: "/profiles/one-path", isDirectory: true).standardizedFileURL
    let manual = BrowserTarget(
      id: "manual-firefox-duplicate-metadata",
      browserID: "org.mozilla.firefox",
      label: "Pinned",
      profileIdentifier: "Same",
      profileDisplayName: "Same",
      mode: .normal,
      isEnabled: true,
      sortOrder: 13,
      origin: .manual,
      availability: .available
    )
    let duplicate = firefoxProfile(path: path.path, name: "Same")
    let browser = firefox(profiles: [duplicate, duplicate])
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [manual]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: existing)
    let migrated = try #require(result.targets.first { $0.id == manual.id })

    #expect(migrated.profileIdentity == FirefoxProfileIdentity.identifier(for: path))
    #expect(migrated.profileLaunchPath == path.path)
    #expect(migrated.availability == .available)
  }

  @Test func duplicateNameLegacyManualFirefoxTargetDoesNotGuessDurablePath() throws {
    let manual = BrowserTarget(
      id: "manual-firefox-legacy",
      browserID: "org.mozilla.firefox",
      label: "Pinned",
      profileIdentifier: "Same",
      profileDisplayName: "Same",
      mode: .normal,
      isEnabled: true,
      sortOrder: 12,
      origin: .manual,
      availability: .available
    )
    let browser = firefox(
      profiles: [
        firefoxProfile(path: "/profiles/one", name: "Same"),
        firefoxProfile(path: "/profiles/two", name: "Same"),
      ])
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [manual]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: existing)
    let unresolved = try #require(result.targets.first { $0.id == manual.id })

    #expect(unresolved.profileIdentity == nil)
    #expect(unresolved.availability == .unavailable)
  }

  @Test func unprofiledManualChromiumTargetStaysAvailableWhenProfilesExist() throws {
    let manual = unprofiledManualTarget(browserID: "com.google.Chrome")
    let browser = chrome(profileID: "Profile 1", profileName: "Work")
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [manual]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: existing)

    #expect(try #require(result.targets.first { $0.id == manual.id }).availability == .available)
  }

  @Test func unprofiledManualFirefoxTargetStaysAvailableWhenProfilesExist() throws {
    let manual = unprofiledManualTarget(browserID: "org.mozilla.firefox")
    let browser = firefox(profilePath: URL(fileURLWithPath: "/profiles/work"), profileName: "Work")
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [manual]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: existing)

    #expect(try #require(result.targets.first { $0.id == manual.id }).availability == .available)
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

    let profileIdentity = FirefoxProfileIdentity.identifier(for: path)
    let profiledTargets = result.targets.filter { $0.profileIdentity == profileIdentity }
    #expect(profiledTargets.count == 3)
    #expect(profiledTargets.allSatisfy { $0.availability == .unavailable })
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
    #expect(updated.profileIdentity == FirefoxProfileIdentity.identifier(for: path))
    #expect(updated.profileLaunchPath == path.path)
    #expect(updated.label == "Pinned")
    #expect(!updated.isEnabled)
  }

  @Test func legacyAbsolutePathDetectedTargetsMigrateToOpaqueIdentityWithoutDuplicate() throws {
    let path = URL(
      fileURLWithPath: "/Users/private-user/Library/Application Support/Firefox/Profiles/work",
      isDirectory: true
    ).standardizedFileURL
    let legacy = BrowserTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: "org.mozilla.firefox",
        profileIdentifier: path.path,
        mode: .normal
      ),
      browserID: "org.mozilla.firefox",
      label: "Client Work",
      profileIdentifier: "Old Name",
      profileDisplayName: "Old Name",
      profileIdentity: path.path,
      mode: .normal,
      isEnabled: false,
      sortOrder: 21,
      origin: .detected,
      availability: .available
    )
    let browser = firefox(profilePath: path, profileName: "Renamed")
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [legacy]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: existing)
    let migrated = try #require(
      result.targets.first {
        $0.profileIdentity == FirefoxProfileIdentity.identifier(for: path) && $0.mode == .normal
      })
    let document = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))

    #expect(result.targets.count == 4)
    #expect(Set(result.targets.map(\.id)).count == 4)
    #expect(migrated.id != legacy.id)
    #expect(migrated.id.hasPrefix("org.mozilla.firefox|firefox-profile-v1:"))
    #expect(migrated.profileIdentity?.hasPrefix("firefox-profile-v1:") == true)
    #expect(migrated.profileLaunchPath == path.path)
    #expect(migrated.profileIdentifier == "Renamed")
    #expect(migrated.label == "Client Work")
    #expect(!migrated.isEnabled)
    #expect(migrated.sortOrder == 21)
    #expect(migrated.origin == .detected)
    #expect(!document.contains("/Users"))
    #expect(!document.contains("private-user"))
    #expect(!document.contains(path.path))
  }

  @Test func canonicalFirefoxTargetConsumesEquivalentLegacyPathTarget() throws {
    let path = URL(
      fileURLWithPath: "/Users/private-user/Library/Application Support/Firefox/Profiles/work",
      isDirectory: true
    ).standardizedFileURL
    let identity = FirefoxProfileIdentity.identifier(for: path)
    let browser = firefox(profilePath: path, profileName: "Renamed")

    for mode in [BrowserMode.normal, .private] {
      let canonical = BrowserTarget(
        id: BrowserCatalog.targetID(
          bundleIdentifier: "org.mozilla.firefox",
          profileIdentifier: identity,
          mode: mode
        ),
        browserID: "org.mozilla.firefox",
        label: "Canonical Customization",
        profileIdentifier: "Work",
        profileDisplayName: "Work",
        profileIdentity: identity,
        mode: mode,
        isEnabled: false,
        sortOrder: 3,
        origin: .detected,
        availability: .available
      )
      let legacy = BrowserTarget(
        id: BrowserCatalog.targetID(
          bundleIdentifier: "org.mozilla.firefox",
          profileIdentifier: path.path,
          mode: mode
        ),
        browserID: "org.mozilla.firefox",
        label: "Stale Legacy Customization",
        profileIdentifier: "Work",
        profileDisplayName: "Work",
        profileIdentity: path.path,
        mode: mode,
        isEnabled: true,
        sortOrder: 9,
        origin: .detected,
        availability: .available
      )
      let existing = PickViaConfig(
        schemaVersion: 1,
        browsers: [browser.application],
        targets: [canonical, legacy]
      )

      let result = BrowserCatalog.reconcile(discovered: [browser], with: existing)
      let matchingMode = result.targets.filter {
        $0.profileIdentity == identity && $0.mode == mode
      }

      #expect(result.targets.count == 4)
      #expect(matchingMode.count == 1)
      #expect(matchingMode.first?.id == canonical.id)
      #expect(matchingMode.first?.label == "Canonical Customization")
      #expect(matchingMode.first?.isEnabled == false)
      #expect(!result.targets.contains { $0.id == legacy.id })
      #expect(Set(result.targets.map(\.id)).count == result.targets.count)
    }
  }

  @Test func equivalentLegacyFirefoxTargetsChooseEarliestCustomizationAndDeduplicate() throws {
    let path = URL(fileURLWithPath: "/profiles/work", isDirectory: true).standardizedFileURL
    let browser = firefox(profilePath: path, profileName: "Renamed")
    func legacy(id: String, label: String, order: Int) -> BrowserTarget {
      BrowserTarget(
        id: id,
        browserID: browser.application.id,
        label: label,
        profileIdentifier: "Old Name",
        profileDisplayName: "Old Name",
        profileIdentity: path.path,
        mode: .normal,
        isEnabled: false,
        sortOrder: order,
        origin: .detected,
        availability: .available
      )
    }
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [
        legacy(id: "legacy-later", label: "Later", order: 12),
        legacy(id: "legacy-winner", label: "Winner", order: 4),
      ]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: existing)
    let normal = try #require(
      result.targets.first {
        $0.profileIdentity == FirefoxProfileIdentity.identifier(for: path) && $0.mode == .normal
      })

    #expect(result.targets.count == 4)
    #expect(normal.label == "Winner")
    #expect(normal.sortOrder == 4)
    #expect(normal.id.hasPrefix("org.mozilla.firefox|firefox-profile-v1:"))
    #expect(Set(result.targets.map(\.id)).count == result.targets.count)
  }

  @Test func firefoxProfileTargetsBecomeUnavailableWithoutAuthoritativeLaunchPaths() throws {
    let browser = firefox(
      profiles: [
        firefoxProfile(path: "/profiles/one", name: "Same Name"),
        firefoxProfile(path: "/profiles/two", name: "Same Name"),
      ]
    )
    let initial = BrowserCatalog.reconcile(discovered: [browser], with: .initial)
    let detectedNormal = try #require(
      initial.targets.first {
        $0.profileIdentity != nil && $0.mode == .normal
      })
    let manual = BrowserTarget(
      id: "manual-firefox-uuid",
      browserID: detectedNormal.browserID,
      label: "Pinned",
      profileIdentifier: detectedNormal.profileIdentifier,
      profileDisplayName: detectedNormal.profileDisplayName,
      profileIdentity: detectedNormal.profileIdentity,
      profileLaunchPath: detectedNormal.profileLaunchPath,
      mode: .normal,
      isEnabled: true,
      sortOrder: 50,
      origin: .manual,
      availability: .available
    )
    let persisted = PickViaConfig(
      schemaVersion: 1,
      browsers: initial.browsers,
      targets: initial.targets + [manual]
    )
    let decoded = try JSONDecoder().decode(
      PickViaConfig.self,
      from: JSONEncoder().encode(persisted)
    )

    for status in [ProfileMetadataStatus.metadataDamaged, .accessRequired, .accessRevoked] {
      let unavailable = BrowserCatalog.reconcile(
        discovered: [firefox(profiles: [], metadataStatus: status)],
        with: decoded
      )
      let profiled = unavailable.targets.filter { $0.profileIdentity != nil }

      #expect(profiled.count == 5)
      #expect(profiled.allSatisfy { $0.availability == .unavailable })
      #expect(profiled.allSatisfy { $0.profileLaunchPath == nil })
      #expect(profiled.first { $0.id == manual.id }?.origin == .manual)
    }
  }

  @Test func legacyAbsolutePathManualTargetMigratesInMemoryAndPreservesCustomization() throws {
    let path = URL(
      fileURLWithPath: "/Users/private-user/Library/Application Support/Firefox/Profiles/manual",
      isDirectory: true
    ).standardizedFileURL
    let manual = BrowserTarget(
      id: "manual-firefox",
      browserID: "org.mozilla.firefox",
      label: "Pinned",
      profileIdentifier: "Old Name",
      profileDisplayName: "Old Name",
      profileIdentity: path.path,
      mode: .private,
      isEnabled: false,
      sortOrder: 42,
      origin: .manual,
      availability: .available
    )
    let browser = firefox(profilePath: path, profileName: "New Name")
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [manual]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: existing)
    let migrated = try #require(result.targets.first { $0.id == manual.id })
    let document = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))

    #expect(migrated.label == "Pinned")
    #expect(migrated.profileIdentifier == "New Name")
    #expect(migrated.profileDisplayName == "New Name")
    #expect(migrated.profileIdentity?.hasPrefix("firefox-profile-v1:") == true)
    #expect(migrated.profileLaunchPath == path.path)
    #expect(migrated.mode == .private)
    #expect(!migrated.isEnabled)
    #expect(migrated.sortOrder == 42)
    #expect(migrated.origin == .manual)
    #expect(!document.contains(path.path))
  }

  @Test func unavailableLegacyFirefoxTargetIsScrubbedWithoutAuthoritativePathMatch() throws {
    let path = "/Users/private-user/Library/Application Support/Firefox/Profiles/missing"
    let browser = firefox(profiles: [])
    let legacy = BrowserTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: browser.application.id,
        profileIdentifier: path,
        mode: .normal
      ),
      browserID: browser.application.id,
      label: "Missing Profile",
      profileIdentifier: "Missing",
      profileDisplayName: "Missing",
      profileIdentity: path,
      mode: .normal,
      isEnabled: true,
      sortOrder: 9,
      origin: .detected,
      availability: .available
    )
    let existing = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [legacy]
    )

    let result = BrowserCatalog.reconcile(discovered: [], with: existing)
    let migrated = try #require(result.targets.first)
    let document = try #require(String(data: JSONEncoder().encode(result), encoding: .utf8))

    #expect(migrated.profileIdentity?.hasPrefix("firefox-profile-v1:") == true)
    #expect(migrated.id.hasPrefix("org.mozilla.firefox|firefox-profile-v1:"))
    #expect(migrated.profileLaunchPath == nil)
    #expect(migrated.availability == .unavailable)
    #expect(!document.contains(path))
    #expect(!document.contains("private-user"))
  }

  @Test func legacyDefaultPairMigratesWithoutLosingCustomization() throws {
    let legacyDefaultPath = "/profiles/chromium-default"
    let browser = chrome(profiles: [
      DiscoveredProfile(
        identifier: "Default", displayName: "Personal", directoryURL: nil,
        isDefault: true),
      DiscoveredProfile(identifier: "Profile 1", displayName: "Work", directoryURL: nil),
    ])
    let legacyNormal = catalogTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: browser.application.id,
        profileIdentifier: "Default",
        mode: .normal),
      browser: browser.application,
      label: "My Chrome",
      profileIdentifier: "Default",
      profileDisplayName: "Personal",
      profileIdentity: "Default",
      profileLaunchPath: legacyDefaultPath,
      mode: .normal,
      isEnabled: false,
      sortOrder: 17
    )
    let legacyPrivate = catalogTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: browser.application.id,
        profileIdentifier: "Default",
        mode: .private),
      browser: browser.application,
      label: "Secret Chrome",
      profileIdentifier: "Default",
      profileDisplayName: "Personal",
      profileIdentity: "Default",
      mode: .private,
      isEnabled: true,
      sortOrder: 18
    )
    let config = PickViaConfig(
      schemaVersion: 1, browsers: [browser.application], targets: [legacyNormal, legacyPrivate])

    let result = BrowserCatalog.reconcile(discovered: [browser], with: config)
    let migrated = result.targets.filter {
      $0.browserID == browser.application.id && $0.profileIdentifier == nil
    }

    #expect(migrated.map(\.label) == ["My Chrome", "Secret Chrome"])
    #expect(migrated.map(\.isEnabled) == [false, true])
    #expect(migrated.map(\.sortOrder) == [17, 18])
    #expect(
      migrated.allSatisfy {
        $0.profileDisplayName == nil && $0.profileIdentity == nil && $0.profileLaunchPath == nil
      })
    #expect(!result.targets.contains { $0.profileIdentity == "Default" })
    #expect(!result.targets.contains { $0.profileLaunchPath == legacyDefaultPath })
  }

  @Test func schemaOneChromiumPrivateDefaultUsesBrowserDefaultMatrixAfterDirectDiscovery()
    throws
  {
    let profile = DiscoveredProfile(
      identifier: "Default",
      displayName: "Personal",
      directoryURL: nil,
      isDefault: true
    )
    let browser = chrome(profiles: [profile])
    let migrated = try schemaOneConfig(
      browser: browser.application,
      legacyPrivateDefault: profile
    ).validatedAndMigrated()

    #expect(try #require(migrated.targets.first).isEnabled == false)

    let reconciled = BrowserCatalog.reconcile(discovered: [browser], with: migrated)
    let privateDefault = try #require(
      reconciled.targets.first {
        $0.browserID == browser.application.id
          && $0.profileIdentity == nil
          && $0.mode == .private
      }
    )

    #expect(privateDefault.isEnabled)
    #expect(!privateDefault.pendingDefaultMigration)
  }

  @Test func schemaOneFirefoxPrivateDefaultUsesBrowserDefaultMatrixAfterDirectDiscovery()
    throws
  {
    let directory = URL(fileURLWithPath: "/profiles/default-release", isDirectory: true)
    let profile = DiscoveredProfile(
      identifier: FirefoxProfileIdentity.identifier(for: directory),
      displayName: "default-release",
      directoryURL: directory,
      launchIdentifier: "default-release",
      isDefault: true
    )
    let browser = firefox(profiles: [profile])
    let migrated = try schemaOneConfig(
      browser: browser.application,
      legacyPrivateDefault: profile
    ).validatedAndMigrated()

    #expect(try #require(migrated.targets.first).isEnabled == false)

    let reconciled = BrowserCatalog.reconcile(discovered: [browser], with: migrated)
    let privateDefault = try #require(
      reconciled.targets.first {
        $0.browserID == browser.application.id
          && $0.profileIdentity == nil
          && $0.mode == .private
      }
    )

    #expect(privateDefault.isEnabled)
    #expect(!privateDefault.pendingDefaultMigration)
  }

  @Test func schemaOneDecodedAbsoluteFirefoxPrivateDefaultCanonicalizesAfterDirectDiscovery()
    throws
  {
    let directory = URL(
      fileURLWithPath: "/profiles/legacy-default-release",
      isDirectory: true
    ).standardizedFileURL
    let profile = DiscoveredProfile(
      identifier: FirefoxProfileIdentity.identifier(for: directory),
      displayName: "default-release",
      directoryURL: directory,
      launchIdentifier: "default-release",
      isDefault: true
    )
    let browser = firefox(profiles: [profile])
    let stored = catalogTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: browser.application.bundleIdentifier,
        profileIdentifier: directory.path,
        mode: .private
      ),
      browser: browser.application,
      label: "Legacy Private Default",
      profileIdentifier: profile.launchIdentifier,
      profileDisplayName: profile.displayName,
      profileIdentity: directory.path,
      profileLaunchPath: directory.path,
      mode: .private,
      isEnabled: true,
      sortOrder: 8
    )
    let decoded = try JSONDecoder().decode(
      BrowserTarget.self,
      from: JSONEncoder().encode(stored)
    )
    #expect(decoded.profileIdentity == directory.path)
    #expect(decoded.profileLaunchPath == nil)
    let migrated = try PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [decoded]
    ).validatedAndMigrated()

    let migratedPrivate = try #require(migrated.targets.first)
    #expect(!migratedPrivate.isEnabled)
    #expect(migratedPrivate.pendingDefaultMigration)

    let reconciled = BrowserCatalog.reconcile(discovered: [browser], with: migrated)
    let privateTargets = reconciled.targets.filter {
      $0.browserID == browser.application.id
        && $0.origin == .detected
        && $0.mode == .private
    }
    let privateDefault = try #require(privateTargets.first)

    #expect(privateTargets.count == 1)
    #expect(
      privateDefault.id
        == BrowserCatalog.targetID(
          bundleIdentifier: browser.application.bundleIdentifier,
          profileIdentifier: nil,
          mode: .private
        )
    )
    #expect(privateDefault.profileIdentity == nil)
    #expect(privateDefault.isEnabled)
    #expect(!privateDefault.pendingDefaultMigration)
  }

  @Test func schemaOneChromiumPrivateDefaultUsesBrowserDefaultMatrixAfterAccessFirstDiscovery()
    throws
  {
    let profile = DiscoveredProfile(
      identifier: "Default",
      displayName: "Personal",
      directoryURL: nil,
      isDefault: true
    )
    let inaccessible = chrome(profiles: [], metadataStatus: .accessRequired)
    let loaded = chrome(profiles: [profile])
    let migrated = try schemaOneConfig(
      browser: inaccessible.application,
      legacyPrivateDefault: profile
    ).validatedAndMigrated()

    let waiting = try BrowserCatalog.reconcile(discovered: [inaccessible], with: migrated)
      .validatedAndMigrated()
    let reconciled = BrowserCatalog.reconcile(discovered: [loaded], with: waiting)
    let privateDefault = try #require(
      reconciled.targets.first {
        $0.browserID == loaded.application.id
          && $0.profileIdentity == nil
          && $0.mode == .private
      }
    )

    #expect(privateDefault.isEnabled)
    #expect(!privateDefault.pendingDefaultMigration)
  }

  @Test func schemaOneFirefoxPrivateDefaultUsesBrowserDefaultMatrixAfterAccessFirstDiscovery()
    throws
  {
    let directory = URL(fileURLWithPath: "/profiles/default-release", isDirectory: true)
    let profile = DiscoveredProfile(
      identifier: FirefoxProfileIdentity.identifier(for: directory),
      displayName: "default-release",
      directoryURL: directory,
      launchIdentifier: "default-release",
      isDefault: true
    )
    let inaccessible = firefox(profiles: [], metadataStatus: .accessRequired)
    let loaded = firefox(profiles: [profile])
    let migrated = try schemaOneConfig(
      browser: inaccessible.application,
      legacyPrivateDefault: profile
    ).validatedAndMigrated()

    let waiting = try BrowserCatalog.reconcile(discovered: [inaccessible], with: migrated)
      .validatedAndMigrated()
    let reconciled = BrowserCatalog.reconcile(discovered: [loaded], with: waiting)
    let privateDefault = try #require(
      reconciled.targets.first {
        $0.browserID == loaded.application.id
          && $0.profileIdentity == nil
          && $0.mode == .private
      }
    )

    #expect(privateDefault.isEnabled)
    #expect(!privateDefault.pendingDefaultMigration)
  }

  @Test func schemaTwoPrivateDefaultChoiceSurvivesLegacyDefaultCanonicalization() throws {
    let profile = DiscoveredProfile(
      identifier: "Default",
      displayName: "Personal",
      directoryURL: nil,
      isDefault: true
    )
    let browser = chrome(profiles: [profile])
    let privateTarget = catalogTarget(
      browser: browser.application,
      label: "Private Default",
      profileIdentifier: profile.launchIdentifier,
      profileDisplayName: profile.displayName,
      profileIdentity: profile.identifier,
      mode: .private,
      isEnabled: false,
      sortOrder: 8
    )
    let current = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [browser.application],
      targets: [privateTarget]
    )

    let reconciled = BrowserCatalog.reconcile(discovered: [browser], with: current)
    let privateDefault = try #require(
      reconciled.targets.first {
        $0.browserID == browser.application.id
          && $0.profileIdentity == nil
          && $0.mode == .private
      }
    )

    #expect(!privateDefault.isEnabled)
  }

  @Test func postMigrationPrivateDefaultChoiceWinsAfterAccessFirstDiscovery() throws {
    let profile = DiscoveredProfile(
      identifier: "Default",
      displayName: "Personal",
      directoryURL: nil,
      isDefault: true
    )
    let inaccessible = chrome(profiles: [], metadataStatus: .accessRequired)
    let loaded = chrome(profiles: [profile])
    let migrated = try schemaOneConfig(
      browser: inaccessible.application,
      legacyPrivateDefault: profile
    ).validatedAndMigrated()
    let waiting = try BrowserCatalog.reconcile(discovered: [inaccessible], with: migrated)
      .validatedAndMigrated()
    let canonicalPrivateID = BrowserCatalog.targetID(
      bundleIdentifier: inaccessible.application.bundleIdentifier,
      profileIdentifier: nil,
      mode: .private
    )
    let userEdited = PickViaConfig(
      schemaVersion: waiting.schemaVersion,
      browsers: waiting.browsers,
      targets: waiting.targets.map { target in
        target.id == canonicalPrivateID
          ? copy(target, label: target.label, enabled: false)
          : target
      }
    )

    let reconciled = BrowserCatalog.reconcile(discovered: [loaded], with: userEdited)
    let privateDefault = try #require(
      reconciled.targets.first { $0.id == canonicalPrivateID }
    )

    #expect(!privateDefault.isEnabled)
    #expect(!privateDefault.pendingDefaultMigration)
  }

  @Test func accessFirstDefaultMigrationRetainsLegacyCustomizationAfterMetadataLoads() throws {
    let inaccessible = chrome(profiles: [], metadataStatus: .accessRequired)
    let loaded = chrome(profiles: [
      DiscoveredProfile(
        identifier: "Default",
        displayName: "Personal",
        directoryURL: nil,
        isDefault: true
      )
    ])
    let legacyNormal = catalogTarget(
      browser: inaccessible.application,
      label: "My Chrome",
      profileIdentifier: "Default",
      profileDisplayName: "Personal",
      profileIdentity: "Default",
      mode: .normal,
      isEnabled: false,
      sortOrder: 17
    )
    let legacyPrivate = catalogTarget(
      browser: inaccessible.application,
      label: "Secret Chrome",
      profileIdentifier: "Default",
      profileDisplayName: "Personal",
      profileIdentity: "Default",
      mode: .private,
      isEnabled: true,
      sortOrder: 18
    )
    let legacy = PickViaConfig(
      schemaVersion: 1,
      browsers: [inaccessible.application],
      targets: [legacyNormal, legacyPrivate]
    )

    let waiting = BrowserCatalog.reconcile(discovered: [inaccessible], with: legacy)
    let pendingDefaults = waiting.targets.filter {
      $0.browserID == inaccessible.application.id
        && $0.origin == .detected
        && $0.profileIdentifier == nil
        && $0.profileIdentity == nil
    }
    #expect(pendingDefaults.count == 2)
    #expect(pendingDefaults.allSatisfy { $0.pendingDefaultMigration })
    #expect(
      waiting.targets.filter { $0.profileIdentity == "Default" }
        .allSatisfy { !$0.pendingDefaultMigration })

    let result = BrowserCatalog.reconcile(discovered: [loaded], with: waiting)
    let defaults = result.targets.filter {
      $0.browserID == loaded.application.id
        && $0.profileIdentifier == nil
        && $0.profileIdentity == nil
    }

    #expect(defaults.map(\.label) == ["My Chrome", "Secret Chrome"])
    #expect(defaults.map(\.isEnabled) == [false, true])
    #expect(defaults.map(\.sortOrder) == [17, 18])
    #expect(defaults.allSatisfy { !$0.pendingDefaultMigration })
    #expect(!result.targets.contains { $0.profileIdentity == "Default" })
  }

  @Test func authoritativeDefaultWithoutLegacyMatchClearsPendingMigration() throws {
    let inaccessible = chrome(profiles: [], metadataStatus: .metadataDamaged)
    let loaded = chrome(profiles: [
      DiscoveredProfile(
        identifier: "Default",
        displayName: "Personal",
        directoryURL: nil,
        isDefault: true
      )
    ])
    let legacy = catalogTarget(
      browser: inaccessible.application,
      label: "Old Profile",
      profileIdentifier: "Profile 9",
      profileDisplayName: "Old Profile",
      profileIdentity: "Profile 9",
      mode: .normal,
      isEnabled: false,
      sortOrder: 4
    )
    let waiting = BrowserCatalog.reconcile(
      discovered: [inaccessible],
      with: PickViaConfig(
        schemaVersion: 1,
        browsers: [inaccessible.application],
        targets: [legacy]
      )
    )
    let canonicalID = BrowserCatalog.targetID(
      bundleIdentifier: inaccessible.application.bundleIdentifier,
      profileIdentifier: nil,
      mode: .normal
    )
    let pending = try #require(waiting.targets.first { $0.id == canonicalID })
    #expect(pending.pendingDefaultMigration)

    let result = BrowserCatalog.reconcile(discovered: [loaded], with: waiting)
    let canonical = try #require(result.targets.first { $0.id == canonicalID })

    #expect(canonical.label == "Google Chrome")
    #expect(canonical.isEnabled)
    #expect(!canonical.pendingDefaultMigration)
    #expect(result.targets.contains { $0.profileIdentity == "Profile 9" })
  }

  @Test func inaccessibleMetadataWithoutLegacyProfileRowsDoesNotMarkGeneratedDefaults() {
    let inaccessible = chrome(profiles: [], metadataStatus: .accessRequired)

    let result = BrowserCatalog.reconcile(
      discovered: [inaccessible],
      with: PickViaConfig(
        schemaVersion: 1,
        browsers: [inaccessible.application],
        targets: [unprofiledManualTarget(browserID: inaccessible.application.id)]
      )
    )
    let generatedDefaults = result.targets.filter {
      $0.browserID == inaccessible.application.id
        && $0.origin == .detected
        && $0.profileIdentifier == nil
        && $0.profileIdentity == nil
    }

    #expect(generatedDefaults.count == 2)
    #expect(generatedDefaults.allSatisfy { !$0.pendingDefaultMigration })
    #expect(
      result.targets.filter { $0.origin == .manual }.allSatisfy {
        !$0.pendingDefaultMigration
      })
  }

  @Test func accessFirstDefaultMigrationSurvivesPreexistingSafariCanonicalTarget() throws {
    let safariApplication = BrowserApplication(
      id: "com.apple.Safari",
      family: .safari,
      displayName: "Safari",
      bundleIdentifier: "com.apple.Safari",
      applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"),
      executableURL: nil,
      isAvailable: true
    )
    let safari = DiscoveredBrowser(
      application: safariApplication,
      profiles: [],
      metadataStatus: .notApplicable
    )
    let inaccessible = chrome(profiles: [], metadataStatus: .accessRequired)
    let loaded = chrome(profiles: [
      DiscoveredProfile(
        identifier: "Default",
        displayName: "Personal",
        directoryURL: nil,
        isDefault: true
      )
    ])
    let safariTarget = catalogTarget(
      browser: safariApplication,
      label: "Safari",
      profileIdentifier: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 0
    )
    let legacyNormal = catalogTarget(
      browser: inaccessible.application,
      label: "My Chrome",
      profileIdentifier: "Default",
      profileDisplayName: "Personal",
      profileIdentity: "Default",
      mode: .normal,
      isEnabled: false,
      sortOrder: 17
    )
    let legacyPrivate = catalogTarget(
      browser: inaccessible.application,
      label: "Secret Chrome",
      profileIdentifier: "Default",
      profileDisplayName: "Personal",
      profileIdentity: "Default",
      mode: .private,
      isEnabled: true,
      sortOrder: 18
    )
    let waiting = BrowserCatalog.reconcile(
      discovered: [safari, inaccessible],
      with: PickViaConfig(
        schemaVersion: 1,
        browsers: [safariApplication, inaccessible.application],
        targets: [safariTarget, legacyNormal, legacyPrivate]
      )
    )
    let waitingSafari = try #require(waiting.targets.first { $0.browserID == safariApplication.id })
    #expect(!waitingSafari.pendingDefaultMigration)

    let result = BrowserCatalog.reconcile(discovered: [safari, loaded], with: waiting)
    let defaults = result.targets.filter {
      $0.browserID == loaded.application.id
        && $0.origin == .detected
        && $0.profileIdentifier == nil
        && $0.profileIdentity == nil
    }

    #expect(defaults.map(\.label) == ["My Chrome", "Secret Chrome"])
    #expect(defaults.map(\.isEnabled) == [false, true])
    #expect(defaults.map(\.sortOrder) == [17, 18])
    #expect(!result.targets.contains { $0.profileIdentity == "Default" })
  }

  @Test func accessFirstDefaultMigrationSurvivesUnrelatedTargetInsertion() throws {
    let inaccessible = chrome(profiles: [], metadataStatus: .accessRevoked)
    let loaded = chrome(profiles: [
      DiscoveredProfile(
        identifier: "Default",
        displayName: "Personal",
        directoryURL: nil,
        isDefault: true
      )
    ])
    let legacyNormal = catalogTarget(
      browser: inaccessible.application,
      label: "Legacy Normal",
      profileIdentifier: "Default",
      profileDisplayName: "Personal",
      profileIdentity: "Default",
      mode: .normal,
      isEnabled: false,
      sortOrder: 10
    )
    let legacyPrivate = catalogTarget(
      browser: inaccessible.application,
      label: "Legacy Private",
      profileIdentifier: "Default",
      profileDisplayName: "Personal",
      profileIdentity: "Default",
      mode: .private,
      isEnabled: true,
      sortOrder: 11
    )
    let waiting = BrowserCatalog.reconcile(
      discovered: [inaccessible],
      with: PickViaConfig(
        schemaVersion: 1,
        browsers: [inaccessible.application],
        targets: [legacyNormal, legacyPrivate]
      )
    )
    let changedWaiting = PickViaConfig(
      schemaVersion: waiting.schemaVersion,
      browsers: waiting.browsers,
      targets: waiting.targets + [unprofiledManualTarget(browserID: inaccessible.application.id)]
    )

    let result = BrowserCatalog.reconcile(discovered: [loaded], with: changedWaiting)
    let defaults = result.targets.filter {
      $0.browserID == loaded.application.id
        && $0.origin == .detected
        && $0.profileIdentifier == nil
        && $0.profileIdentity == nil
    }

    #expect(defaults.map(\.label) == ["Legacy Normal", "Legacy Private"])
    #expect(defaults.map(\.isEnabled) == [false, true])
    #expect(defaults.map(\.sortOrder) == [10, 11])
    #expect(!result.targets.contains { $0.profileIdentity == "Default" })
  }

  @Test func editedInterimCanonicalDefaultWinsWhileUntouchedPeerMigratesLegacyCustomization()
    throws
  {
    let inaccessible = chrome(profiles: [], metadataStatus: .accessRevoked)
    let loaded = chrome(profiles: [
      DiscoveredProfile(
        identifier: "Default",
        displayName: "Personal",
        directoryURL: nil,
        isDefault: true
      )
    ])
    let legacyNormal = catalogTarget(
      browser: inaccessible.application,
      label: "Legacy Normal",
      profileIdentifier: "Default",
      profileDisplayName: "Personal",
      profileIdentity: "Default",
      mode: .normal,
      isEnabled: false,
      sortOrder: 10
    )
    let legacyPrivate = catalogTarget(
      browser: inaccessible.application,
      label: "Legacy Private",
      profileIdentifier: "Default",
      profileDisplayName: "Personal",
      profileIdentity: "Default",
      mode: .private,
      isEnabled: true,
      sortOrder: 11
    )
    let waiting = BrowserCatalog.reconcile(
      discovered: [inaccessible],
      with: PickViaConfig(
        schemaVersion: 1,
        browsers: [inaccessible.application],
        targets: [legacyNormal, legacyPrivate]
      )
    )
    let canonicalNormalID = BrowserCatalog.targetID(
      bundleIdentifier: inaccessible.application.bundleIdentifier,
      profileIdentifier: nil,
      mode: .normal
    )
    let editedTargets = waiting.targets.map { target in
      target.id == canonicalNormalID
        ? copy(target, label: target.label, enabled: target.isEnabled, sortOrder: 2)
        : target
    }
    let editedWaiting = PickViaConfig(
      schemaVersion: waiting.schemaVersion,
      browsers: waiting.browsers,
      targets: editedTargets
    )

    let result = BrowserCatalog.reconcile(discovered: [loaded], with: editedWaiting)
    let normal = try #require(result.targets.first { $0.id == canonicalNormalID })
    let privateID = BrowserCatalog.targetID(
      bundleIdentifier: inaccessible.application.bundleIdentifier,
      profileIdentifier: nil,
      mode: .private
    )
    let privateTarget = try #require(result.targets.first { $0.id == privateID })

    #expect(normal.label == "Google Chrome")
    #expect(normal.isEnabled)
    #expect(normal.sortOrder == 2)
    #expect(privateTarget.label == "Legacy Private")
    #expect(privateTarget.isEnabled)
    #expect(privateTarget.sortOrder == 11)
    #expect(!result.targets.contains { $0.profileIdentity == "Default" })
  }

  @Test func existingBrowserDefaultWinsButConsumesLegacyDefaultDuplicate() {
    let browser = chrome(profiles: [
      DiscoveredProfile(
        identifier: "Default", displayName: "Personal", directoryURL: nil,
        isDefault: true)
    ])
    let existing = catalogTarget(
      browser: browser.application, label: "Keep Me", profileIdentifier: nil,
      mode: .normal, isEnabled: false, sortOrder: 4)
    let legacy = catalogTarget(
      browser: browser.application, label: "Discard Me", profileIdentifier: "Default",
      profileDisplayName: "Personal", profileIdentity: "Default",
      mode: .normal, isEnabled: true, sortOrder: 9)
    let config = PickViaConfig(
      schemaVersion: 1, browsers: [browser.application], targets: [existing, legacy])

    let result = BrowserCatalog.reconcile(discovered: [browser], with: config)

    #expect(result.targets.filter { $0.mode == .normal }.map(\.label) == ["Keep Me"])
    #expect(!result.targets.contains { $0.id == legacy.id })
  }

  @Test func browserDefaultRemainsAvailableWhenNamedProfilesExist() throws {
    let browser = chrome(profiles: [
      DiscoveredProfile(identifier: "Profile 1", displayName: "Work", directoryURL: nil)
    ])
    let existing = catalogTarget(
      browser: browser.application, label: "Default", profileIdentifier: nil,
      mode: .normal, isEnabled: true, sortOrder: 0, availability: .unavailable)
    let config = PickViaConfig(
      schemaVersion: 1, browsers: [browser.application], targets: [existing])

    let result = BrowserCatalog.reconcile(discovered: [browser], with: config)
    let defaultTarget = try #require(result.targets.first { $0.profileIdentifier == nil })

    #expect(defaultTarget.availability == .available)
  }

  @Test func legacyManualSafariAvailabilityRemainsFamilySpecific() throws {
    let application = BrowserApplication(
      id: "com.apple.Safari",
      family: .safari,
      displayName: "Safari",
      bundleIdentifier: "com.apple.Safari",
      applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"),
      executableURL: nil,
      isAvailable: true
    )
    func safari(metadataStatus: ProfileMetadataStatus) -> DiscoveredBrowser {
      DiscoveredBrowser(
        application: application,
        profiles: [],
        metadataStatus: metadataStatus
      )
    }
    func manualTarget(
      id: String,
      profileDisplayName: String?,
      profileIdentity: String?,
      profileLaunchPath: String?
    ) -> BrowserTarget {
      BrowserTarget(
        id: id,
        browserID: application.id,
        label: "Legacy Safari",
        profileIdentifier: nil,
        profileDisplayName: profileDisplayName,
        profileIdentity: profileIdentity,
        profileLaunchPath: profileLaunchPath,
        mode: .normal,
        isEnabled: true,
        sortOrder: 20,
        origin: .manual,
        availability: .unavailable
      )
    }

    let legacy = manualTarget(
      id: "manual-safari-legacy",
      profileDisplayName: "Legacy Profile",
      profileIdentity: "legacy-profile",
      profileLaunchPath: "/legacy/safari/profile"
    )
    let loaded = BrowserCatalog.reconcile(
      discovered: [safari(metadataStatus: .loaded)],
      with: PickViaConfig(schemaVersion: 1, browsers: [application], targets: [legacy])
    )

    #expect(try #require(loaded.targets.first { $0.id == legacy.id }).availability == .available)

    let canonicalManual = manualTarget(
      id: "manual-safari-default",
      profileDisplayName: nil,
      profileIdentity: nil,
      profileLaunchPath: nil
    )
    let damaged = BrowserCatalog.reconcile(
      discovered: [safari(metadataStatus: .metadataDamaged)],
      with: PickViaConfig(
        schemaVersion: 1,
        browsers: [application],
        targets: [canonicalManual]
      )
    )

    #expect(
      try #require(damaged.targets.first { $0.id == canonicalManual.id }).availability
        == .unavailable)
  }

  @Test func legacyDetectedSafariTargetMigratesWithoutDuplicate() throws {
    let application = BrowserApplication(
      id: "com.apple.Safari",
      family: .safari,
      displayName: "Safari",
      bundleIdentifier: "com.apple.Safari",
      applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"),
      executableURL: nil,
      isAvailable: true
    )
    let browser = DiscoveredBrowser(
      application: application,
      profiles: [],
      metadataStatus: .notApplicable
    )
    let legacy = catalogTarget(
      id: "legacy-safari-normal",
      browser: application,
      label: "My Safari",
      profileIdentifier: nil,
      mode: .normal,
      isEnabled: false,
      sortOrder: 7,
      availability: .unavailable
    )
    let config = PickViaConfig(
      schemaVersion: 1,
      browsers: [application],
      targets: [legacy]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: config)
    let target = try #require(result.targets.first)

    #expect(result.targets.count == 1)
    #expect(
      target.id
        == BrowserCatalog.targetID(
          bundleIdentifier: application.bundleIdentifier,
          profileIdentifier: nil,
          mode: .normal
        ))
    #expect(target.label == "My Safari")
    #expect(!target.isEnabled)
    #expect(target.sortOrder == 7)
    #expect(target.availability == .available)
    #expect(!result.targets.contains { $0.id == legacy.id })
  }

  @Test func structuralBrowserLevelTargetRemainsAvailableAcrossMetadataStatuses() throws {
    let statuses: [ProfileMetadataStatus] = [
      .metadataAbsent, .loaded, .accessRequired, .accessRevoked, .metadataDamaged,
    ]
    for family in [BrowserFamily.chromium, .firefox] {
      for status in statuses {
        let browser =
          family == .chromium
          ? chrome(profiles: [], metadataStatus: status)
          : firefox(profiles: [], metadataStatus: status)
        let manual = unprofiledManualTarget(browserID: browser.application.id)
        let config = PickViaConfig(
          schemaVersion: 1, browsers: [browser.application], targets: [manual])

        let result = BrowserCatalog.reconcile(discovered: [browser], with: config)
        let reconciled = try #require(result.targets.first { $0.id == manual.id })

        #expect(reconciled.availability == .available)
      }
    }
  }

  @Test func profileDisplayNameOnlyIsNeverTreatedAsBrowserLevel() throws {
    let statuses: [ProfileMetadataStatus] = [
      .metadataAbsent, .loaded, .accessRequired, .accessRevoked, .metadataDamaged,
    ]
    for family in [BrowserFamily.chromium, .firefox] {
      for status in statuses {
        let browser =
          family == .chromium
          ? chrome(profiles: [], metadataStatus: status)
          : firefox(profiles: [], metadataStatus: status)
        let stale = catalogTarget(
          id: "stale-display-name-\(family)-\(status)",
          browser: browser.application,
          label: "Stale Profile",
          profileIdentifier: nil,
          profileDisplayName: "Stale Profile",
          mode: .normal,
          isEnabled: true,
          sortOrder: 20,
          availability: .available
        )
        let config = PickViaConfig(
          schemaVersion: 1, browsers: [browser.application], targets: [stale])

        let result = BrowserCatalog.reconcile(discovered: [browser], with: config)
        let reconciled = try #require(result.targets.first { $0.id == stale.id })

        #expect(reconciled.availability == .unavailable)
      }
    }
  }

  @Test func profileLaunchPathOnlyIsNeverTreatedAsBrowserLevel() throws {
    let statuses: [ProfileMetadataStatus] = [
      .metadataAbsent, .loaded, .accessRequired, .accessRevoked, .metadataDamaged,
    ]
    for family in [BrowserFamily.chromium, .firefox] {
      for status in statuses {
        let browser =
          family == .chromium
          ? chrome(profiles: [], metadataStatus: status)
          : firefox(profiles: [], metadataStatus: status)
        let stale = catalogTarget(
          id: "stale-launch-path-\(family)-\(status)",
          browser: browser.application,
          label: "Stale Profile",
          profileIdentifier: nil,
          profileLaunchPath: "/profiles/stale",
          mode: .normal,
          isEnabled: true,
          sortOrder: 20,
          availability: .available
        )
        let config = PickViaConfig(
          schemaVersion: 1, browsers: [browser.application], targets: [stale])

        let result = BrowserCatalog.reconcile(discovered: [browser], with: config)
        let reconciled = try #require(result.targets.first { $0.id == stale.id })

        #expect(reconciled.availability == .unavailable)
      }
    }
  }

  @Test func multipleLegacyDefaultMatchesChooseStableCustomizationAndConsumeDuplicates() throws {
    let path = URL(fileURLWithPath: "/profiles/default", isDirectory: true).standardizedFileURL
    let browser = chrome(profiles: [
      DiscoveredProfile(
        identifier: "Default",
        displayName: "Personal",
        directoryURL: path,
        isDefault: true
      )
    ])
    let winner = catalogTarget(
      id: "a-legacy-winner",
      browser: browser.application,
      label: "Winner",
      profileIdentifier: "Default",
      mode: .normal,
      isEnabled: false,
      sortOrder: 4
    )
    let tiedDuplicate = catalogTarget(
      id: "z-legacy-tie",
      browser: browser.application,
      label: "Tie Loser",
      profileIdentifier: "Other",
      profileIdentity: "Default",
      mode: .normal,
      isEnabled: true,
      sortOrder: 4
    )
    let laterDuplicate = catalogTarget(
      id: "legacy-later",
      browser: browser.application,
      label: "Later",
      profileIdentifier: "Other",
      profileLaunchPath: path.path,
      mode: .normal,
      isEnabled: true,
      sortOrder: 12
    )
    let config = PickViaConfig(
      schemaVersion: 1,
      browsers: [browser.application],
      targets: [laterDuplicate, tiedDuplicate, winner]
    )

    let result = BrowserCatalog.reconcile(discovered: [browser], with: config)
    let normal = try #require(
      result.targets.first {
        $0.browserID == browser.application.id && $0.mode == .normal
      })

    #expect(normal.label == "Winner")
    #expect(!normal.isEnabled)
    #expect(normal.sortOrder == 4)
    #expect(normal.profileIdentifier == nil)
    #expect(normal.profileDisplayName == nil)
    #expect(normal.profileIdentity == nil)
    #expect(normal.profileLaunchPath == nil)
    #expect(
      !result.targets.contains {
        [winner.id, tiedDuplicate.id, laterDuplicate.id].contains($0.id)
      })
  }

  @Test func nonAuthoritativeProfilesDoNotTriggerLegacyDefaultMigration() throws {
    let browser = chrome(
      profiles: [
        DiscoveredProfile(
          identifier: "Default", displayName: "Stale Personal", directoryURL: nil,
          isDefault: true)
      ],
      metadataStatus: .accessRequired
    )
    let legacy = catalogTarget(
      browser: browser.application,
      label: "Stale Customization",
      profileIdentifier: "Default",
      profileDisplayName: "Stale Personal",
      profileIdentity: "Default",
      mode: .normal,
      isEnabled: false,
      sortOrder: 7
    )
    let config = PickViaConfig(
      schemaVersion: 1, browsers: [browser.application], targets: [legacy])

    let result = BrowserCatalog.reconcile(discovered: [browser], with: config)
    let browserDefault = try #require(
      result.targets.first {
        $0.profileIdentifier == nil && $0.mode == .normal
      })
    let preservedLegacy = try #require(result.targets.first { $0.id == legacy.id })

    #expect(browserDefault.label == "Google Chrome")
    #expect(preservedLegacy.label == "Stale Customization")
    #expect(preservedLegacy.availability == .unavailable)
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

    #expect(result.targets.count == 4)
    let normal = result.targets.first { $0.profileIdentity == "Profile 1" && $0.mode == .normal }
    #expect(normal?.label == "Client Work")
    #expect(normal?.isEnabled == false)
    #expect(normal?.sortOrder == 7)
    #expect(normal?.profileDisplayName == "Work")
    #expect(normal?.availability == .available)
    #expect(
      result.targets.first { $0.profileIdentity == "Profile 1" && $0.mode == .private }?.isEnabled
        == false)
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

  @Test func runtimeSanitizedFallbackRetriesDeterministicallyUntilTargetIDIsUnique() throws {
    let firefoxID = "org.mozilla.firefox"
    let chromiumID = "com.google.Chrome"
    let sensitiveTargetID = "/Users/private/Firefox/Profile"
    let sanitizedID =
      "firefox-runtime-target|\(FirefoxProfileIdentity.identifier(forLegacyValue: sensitiveTargetID))"
    let firstFallbackID =
      "firefox-runtime-target|\(FirefoxProfileIdentity.identifier(forLegacyValue: "\(sensitiveTargetID)#2"))"
    let secondFallbackID =
      "firefox-runtime-target|\(FirefoxProfileIdentity.identifier(forLegacyValue: "\(sensitiveTargetID)#2#1"))"

    func blockingTarget(id: String, order: Int) -> BrowserTarget {
      BrowserTarget(
        id: id,
        browserID: chromiumID,
        label: "Occupied \(order)",
        profileIdentifier: nil,
        profileDisplayName: nil,
        mode: .normal,
        isEnabled: true,
        sortOrder: order,
        origin: .manual,
        availability: .available
      )
    }

    let firefoxTarget = BrowserTarget(
      id: sensitiveTargetID,
      browserID: firefoxID,
      label: "Legacy Firefox",
      profileIdentifier: nil,
      profileDisplayName: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 2,
      origin: .manual,
      availability: .available
    )
    let config = PickViaConfig(
      schemaVersion: 1,
      browsers: [chrome(profiles: []).application, firefox(profiles: []).application],
      targets: [
        blockingTarget(id: sanitizedID, order: 0),
        blockingTarget(id: firstFallbackID, order: 1),
        firefoxTarget,
      ]
    )

    let first = BrowserCatalog.runtimeSanitizedFallbackResult(config)
    let second = BrowserCatalog.runtimeSanitizedFallbackResult(config)

    #expect(Set(first.config.targets.map(\.id)).count == first.config.targets.count)
    #expect(first.config.targets[2].id == secondFallbackID)
    #expect(first.config.targets.map(\.id) == second.config.targets.map(\.id))
    #expect(
      first.authoritativeTargetIDByRuntimeTargetID[secondFallbackID] == sensitiveTargetID
    )
    #expect(
      first.authoritativeTargetIDByRuntimeTargetID[sanitizedID] == sanitizedID
    )
    #expect(
      first.authoritativeTargetIDByRuntimeTargetID
        == second.authoritativeTargetIDByRuntimeTargetID
    )
  }
}

private func chrome(profileID: String, profileName: String) -> DiscoveredBrowser {
  chrome(
    profiles: [
      DiscoveredProfile(identifier: profileID, displayName: profileName, directoryURL: nil)
    ])
}

private let chromeDescriptor = BrowserDescriptor.supported.first {
  $0.bundleIdentifier == "com.google.Chrome"
}!

private let firefoxDescriptor = BrowserDescriptor.supported.first {
  $0.bundleIdentifier == "org.mozilla.firefox"
}!

private let duckDuckGoDescriptor = BrowserDescriptor.supported.first {
  $0.bundleIdentifier == DuckDuckGoBuildCompatibilityChecker.bundleIdentifier
}!

private func duckDuckGoCatalog(
  applicationURL: URL,
  compatibility: DuckDuckGoBuildCompatibility,
  fileSystem: any FileSystem = DiscoveryFileSystem(files: [:]),
  profileRootAccess: any ProfileRootAccessProviding = StubProfileRootAccess()
) -> BrowserCatalog {
  BrowserCatalog(
    descriptors: [duckDuckGoDescriptor],
    applicationLocator: StubApplicationLocator(applications: [
      DuckDuckGoBuildCompatibilityChecker.bundleIdentifier: applicationURL
    ]),
    fileSystem: fileSystem,
    profileRootAccess: profileRootAccess,
    duckDuckGoCompatibilityChecker: StubDuckDuckGoCompatibilityChecker(
      compatibility: compatibility
    )
  )
}

private func duckDuckGoBrowser(privateModeIsAvailable: Bool) -> DiscoveredBrowser {
  DiscoveredBrowser(
    application: BrowserApplication(
      id: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
      family: .duckDuckGo,
      displayName: "DuckDuckGo",
      bundleIdentifier: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
      applicationURL: URL(fileURLWithPath: "/Applications/DuckDuckGo.app"),
      executableURL: nil,
      isAvailable: true
    ),
    profiles: [],
    metadataStatus: .notApplicable,
    privateModeIsAvailable: privateModeIsAvailable
  )
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

private func firefox(
  profiles: [DiscoveredProfile],
  metadataStatus: ProfileMetadataStatus = .loaded
) -> DiscoveredBrowser {
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
    profiles: profiles,
    metadataStatus: metadataStatus
  )
}

private func firefoxProfile(path: String, name: String) -> DiscoveredProfile {
  let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  return DiscoveredProfile(
    identifier: FirefoxProfileIdentity.identifier(for: url),
    displayName: name,
    directoryURL: url,
    launchIdentifier: name
  )
}

private func copy(
  _ target: BrowserTarget,
  label: String,
  enabled: Bool,
  sortOrder: Int? = nil
) -> BrowserTarget {
  BrowserTarget(
    id: target.id,
    browserID: target.browserID,
    label: label,
    profileIdentifier: target.profileIdentifier,
    profileDisplayName: target.profileDisplayName,
    profileIdentity: target.profileIdentity,
    profileLaunchPath: target.profileLaunchPath,
    mode: target.mode,
    isEnabled: enabled,
    sortOrder: sortOrder ?? target.sortOrder,
    origin: target.origin,
    availability: target.availability
  )
}

private func catalogTarget(
  id: BrowserTarget.ID? = nil,
  browser: BrowserApplication,
  label: String,
  profileIdentifier: String?,
  profileDisplayName: String? = nil,
  profileIdentity: String? = nil,
  profileLaunchPath: String? = nil,
  mode: BrowserMode,
  isEnabled: Bool,
  sortOrder: Int,
  availability: BrowserTargetAvailability = .available
) -> BrowserTarget {
  BrowserTarget(
    id: id
      ?? BrowserCatalog.targetID(
        bundleIdentifier: browser.bundleIdentifier,
        profileIdentifier: profileIdentity ?? profileIdentifier,
        mode: mode
      ),
    browserID: browser.id,
    label: label,
    profileIdentifier: profileIdentifier,
    profileDisplayName: profileDisplayName,
    profileIdentity: profileIdentity,
    profileLaunchPath: profileLaunchPath,
    mode: mode,
    isEnabled: isEnabled,
    sortOrder: sortOrder,
    origin: .detected,
    availability: availability
  )
}

private func schemaOneConfig(
  browser: BrowserApplication,
  legacyPrivateDefault profile: DiscoveredProfile
) -> PickViaConfig {
  PickViaConfig(
    schemaVersion: 1,
    browsers: [browser],
    targets: [
      catalogTarget(
        browser: browser,
        label: "Legacy Private Default",
        profileIdentifier: profile.launchIdentifier,
        profileDisplayName: profile.displayName,
        profileIdentity: profile.identifier,
        profileLaunchPath: profile.directoryURL?.standardizedFileURL.path,
        mode: .private,
        isEnabled: true,
        sortOrder: 8
      )
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

private func unprofiledManualTarget(browserID: String) -> BrowserTarget {
  BrowserTarget(
    id: "manual-default-\(browserID)",
    browserID: browserID,
    label: "Browser Default",
    profileIdentifier: nil,
    profileDisplayName: nil,
    profileIdentity: nil,
    mode: .normal,
    isEnabled: true,
    sortOrder: 40,
    origin: .manual,
    availability: .unavailable
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

private struct StubDuckDuckGoCompatibilityChecker: DuckDuckGoBuildCompatibilityChecking {
  let compatibility: DuckDuckGoBuildCompatibility

  func compatibility(of url: URL) -> DuckDuckGoBuildCompatibility {
    compatibility
  }
}

private final class StubProfileRootAccess: ProfileRootAccessProviding, @unchecked Sendable {
  private let states: [String: ProfileRootAccessState]
  private let grantedRoots: [String: URL]
  private(set) var requestedBundleIdentifiers: [String] = []
  private(set) var endedBundleIdentifiers: [String] = []

  init(
    states: [String: ProfileRootAccessState] = [:],
    grantedRoots: [String: URL] = [:]
  ) {
    self.states = states
    self.grantedRoots = grantedRoots
  }

  func beginAccess(for bundleIdentifier: String) -> ProfileRootAccessResult {
    requestedBundleIdentifiers.append(bundleIdentifier)
    if let root = grantedRoots[bundleIdentifier] {
      return ProfileRootAccessResult(
        state: .granted,
        lease: ProfileRootLease(root: root) { [weak self] in
          self?.endedBundleIdentifiers.append(bundleIdentifier)
        }
      )
    }
    return ProfileRootAccessResult(
      state: states[bundleIdentifier] ?? .missing,
      lease: nil
    )
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
