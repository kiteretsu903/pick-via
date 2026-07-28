import Foundation
import XCTest

@testable import PickVia
@testable import PickViaCore

@MainActor
final class AppModelTests: XCTestCase {
  func testDensityUsesCompactForMissingAndInvalidPreference() throws {
    let missingModel = makeModel(preferences: PreferencesStub())
    try missingModel.load()
    XCTAssertEqual(missingModel.chooserDensity, .compact)

    let invalidModel = makeModel(preferences: PreferencesStub(integers: ["chooserDensity": 99]))
    try invalidModel.load()
    XCTAssertEqual(invalidModel.chooserDensity, .compact)
  }

  func testDensityLoadsAndPersistsEveryPreset() throws {
    for density in ChooserDensity.allCases {
      let restorationPreferences = PreferencesStub(
        integers: ["chooserDensity": density.rawValue]
      )
      let restoredModel = makeModel(preferences: restorationPreferences)
      try restoredModel.load()
      XCTAssertEqual(restoredModel.chooserDensity, density)

      let persistencePreferences = PreferencesStub()
      let persistenceModel = makeModel(preferences: persistencePreferences)
      try persistenceModel.load()
      persistenceModel.chooserDensity = density
      XCTAssertEqual(persistencePreferences.setIntegers["chooserDensity"], density.rawValue)
    }
  }

  func testDensityDisplayOrderAndNames() {
    XCTAssertEqual(ChooserDensity.allCases, [.compact, .balanced, .spacious])
    XCTAssertEqual(ChooserDensity.allCases.map(\.title), ["Compact", "Balanced", "Spacious"])
  }

  func testLoadPublishesPersistedConfigAndSystemPreferencesOnlyOnce() throws {
    let config = Fixtures.config
    let store = ConfigStoreStub(config: config)
    let preferences = PreferencesStub(
      booleans: ["showsURLInChooser": false],
      integers: ["onboardingStep": 2]
    )
    let defaults = DefaultBrowserSpy(status: .init(http: .isDefault, https: .notDefault))
    let login = LoginItemStub(isEnabled: true)
    let model = makeModel(
      store: store,
      preferences: preferences,
      defaultBrowser: defaults,
      loginItem: login
    )

    try model.load()
    try model.load()

    XCTAssertEqual(model.config, config)
    XCTAssertEqual(model.browsers, config.browsers)
    XCTAssertEqual(model.targets, config.targets)
    XCTAssertFalse(model.showsURLInChooser)
    XCTAssertTrue(model.launchesAtLogin)
    XCTAssertEqual(model.onboardingStep, 2)
    XCTAssertEqual(model.defaultStatus, .init(http: .isDefault, https: .notDefault))
    XCTAssertEqual(store.loadCallCount, 1)
    XCTAssertEqual(defaults.statusCallCount, 1)
  }

  func testStartupRescansLoadedConfigurationAndPreservesCustomization() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let reconciled = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: Fixtures.editableConfig.browsers,
      targets: Fixtures.editableConfig.targets.map {
        $0.id == "work" ? Fixtures.copy($0, label: "Client Work") : $0
      }
    )
    let catalog = BrowserCatalogStub(
      discovered: [Fixtures.discoveredChrome], reconciled: reconciled)
    let model = makeModel(store: store, catalog: catalog)

    try model.load()

    XCTAssertEqual(model.config, reconciled)
    XCTAssertEqual(catalog.reconcileInputs, [Fixtures.editableConfig])
    XCTAssertEqual(store.saved, [reconciled])
  }

  func testDefaultHandlerStatusIncludesMailAndRetainsBrowserSummary() {
    let status = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .notDefault
    )

    XCTAssertEqual(status.http, .isDefault)
    XCTAssertEqual(status.https, .isDefault)
    XCTAssertEqual(status.mailto, .notDefault)
    XCTAssertTrue(status.isDefaultBrowser)
    XCTAssertEqual(
      DefaultHandlerStatus.unknown,
      DefaultHandlerStatus(http: .unknown, https: .unknown, mailto: .unknown)
    )
  }

  func testLoadReconcilesMailWithoutChangingBrowserTargets() throws {
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.browserConfig),
      mailCatalog: .authoritative([Fixtures.appleMailDiscovery])
    )

    try model.load()

    XCTAssertEqual(
      model.targets.filter { $0.routeKind == .web }.map(\.id),
      Fixtures.browserConfig.targets.map(\.id)
    )
    XCTAssertEqual(model.mailTargets.map(\.id), ["mailto|com.apple.mail"])
    XCTAssertEqual(model.mailApplications.map(\.id), ["com.apple.mail"])
  }

  func testLoadReconcilesBrowserWithoutChangingMailTargets() throws {
    let browserReconciled = BrowserCatalog.reconcile(
      discovered: [Fixtures.discoveredChrome],
      with: Fixtures.mailConfig
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.mailConfig),
      catalog: BrowserCatalogStub(
        discovered: [Fixtures.discoveredChrome],
        reconciled: browserReconciled
      ),
      mailCatalog: .nonAuthoritative
    )

    try model.load()

    XCTAssertFalse(model.browsers.isEmpty)
    XCTAssertEqual(model.mailTargets, Fixtures.mailConfig.targets)
    XCTAssertEqual(
      model.mailApplications.map(\.id),
      Fixtures.mailConfig.applications.map(\.id)
    )
  }

  func testNonAuthoritativeBrowserScanStillCommitsAuthoritativeMailSlice() throws {
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.browserConfig),
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(
          browsers: [],
          warnings: [],
          isAuthoritative: false
        )
      ),
      mailCatalog: .authoritative([Fixtures.appleMailDiscovery])
    )

    try model.load()

    XCTAssertEqual(
      model.targets.filter { $0.routeKind == .web },
      Fixtures.browserConfig.targets
    )
    XCTAssertEqual(model.mailTargets.map(\.id), ["mailto|com.apple.mail"])
    XCTAssertEqual(
      model.errorMessage,
      "Browser discovery could not be completed. Existing targets were preserved."
    )
    XCTAssertNil(model.mailErrorMessage)
  }

  func testNonAuthoritativeMailScanStillCommitsAuthoritativeBrowserSlice() throws {
    let browserReconciled = BrowserCatalog.reconcile(
      discovered: [Fixtures.discoveredChromeWithProfiles],
      with: Fixtures.mailConfig
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.mailConfig),
      catalog: BrowserCatalogStub(
        discovered: [Fixtures.discoveredChromeWithProfiles],
        reconciled: browserReconciled
      ),
      mailCatalog: .nonAuthoritative
    )

    try model.load()

    XCTAssertEqual(
      model.targets.filter { $0.routeKind == .web },
      browserReconciled.targets.filter { $0.routeKind == .web }
    )
    XCTAssertEqual(model.mailTargets, Fixtures.mailConfig.targets)
    XCTAssertEqual(
      model.mailErrorMessage,
      "Mail application discovery could not be completed. Existing choices were preserved."
    )
  }

  func testBrowserStartupChangePersistsAuthoritativeMailWhileRuntimeUsesMailFallback() throws {
    let persisted = Fixtures.webAndMailConfig
    let unavailableMail = Fixtures.copy(
      Fixtures.appleMail,
      mailIsAvailable: false
    )
    let runtimeFallback = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: Fixtures.editableConfig.applications + [unavailableMail],
      targets: persisted.targets
    )
    let browserReconciled = BrowserCatalog.reconcile(
      discovered: [Fixtures.discoveredChromeWithProfiles],
      with: persisted
    )
    let store = ConfigStoreStub(config: persisted)
    let snapshot = MutableTargetSnapshot()
    let model = makeModel(
      store: store,
      catalog: BrowserCatalogStub(
        discovered: [Fixtures.discoveredChromeWithProfiles],
        reconciled: browserReconciled
      ),
      mailCatalog: MailCatalogStub(
        scan: MailScanResult(applications: [], isAuthoritative: false),
        runtimeFallback: runtimeFallback
      ),
      targetSnapshot: snapshot
    )

    try model.load()

    let saved = try XCTUnwrap(store.saved.last)
    XCTAssertEqual(saved.mailApplications, persisted.mailApplications)
    XCTAssertEqual(
      saved.targets.filter { $0.routeKind == .mail },
      persisted.targets.filter { $0.routeKind == .mail }
    )
    XCTAssertEqual(
      saved.targets.filter { $0.routeKind == .web },
      browserReconciled.targets.filter { $0.routeKind == .web }
    )
    XCTAssertFalse(try XCTUnwrap(model.mailApplications.first).isAvailable(for: .mail))
    XCTAssertTrue(snapshot.availableSnapshot(for: .mail).targets.isEmpty)
  }

  func testBrowserTargetEditAfterMailFallbackPersistsAuthoritativeMailState() throws {
    let persisted = Fixtures.webAndMailConfig
    let runtimeFallback = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: Fixtures.editableConfig.applications + [
        Fixtures.copy(Fixtures.appleMail, mailIsAvailable: false)
      ],
      targets: persisted.targets
    )
    let store = ConfigStoreStub(config: persisted)
    let snapshot = MutableTargetSnapshot()
    let model = makeModel(
      store: store,
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(
          browsers: [],
          warnings: [],
          isAuthoritative: false
        )
      ),
      mailCatalog: MailCatalogStub(
        scan: MailScanResult(applications: [], isAuthoritative: false),
        runtimeFallback: runtimeFallback
      ),
      targetSnapshot: snapshot
    )
    try model.load()
    store.resetSaved()

    try model.renameTarget(id: "work", label: "Edited Work")

    let saved = try XCTUnwrap(store.saved.last)
    XCTAssertEqual(saved.mailApplications, persisted.mailApplications)
    XCTAssertEqual(
      saved.targets.filter { $0.routeKind == .mail },
      persisted.targets.filter { $0.routeKind == .mail }
    )
    XCTAssertEqual(
      saved.targets.first { $0.id == "work" }?.label,
      "Edited Work"
    )
    XCTAssertFalse(try XCTUnwrap(model.mailApplications.first).isAvailable(for: .mail))
    XCTAssertTrue(snapshot.availableSnapshot(for: .mail).targets.isEmpty)
  }

  func testAuthoritativeBrowserRescanAfterMailFallbackPersistsAuthoritativeMailState() throws {
    let persisted = Fixtures.webAndMailConfig
    let runtimeFallback = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: Fixtures.editableConfig.applications + [
        Fixtures.copy(Fixtures.appleMail, mailIsAvailable: false)
      ],
      targets: persisted.targets
    )
    let browserScan = BrowserScanResult(
      browsers: [Fixtures.discoveredChromeWithProfiles],
      warnings: [],
      isAuthoritative: true
    )
    let browserCatalog = BrowserCatalogStub(
      scanResult: BrowserScanResult(
        browsers: [],
        warnings: [],
        isAuthoritative: false
      ),
      reconciler: { config in
        BrowserCatalog.reconcile(
          discovered: browserScan.browsers,
          with: config
        )
      }
    )
    let store = ConfigStoreStub(config: persisted)
    let snapshot = MutableTargetSnapshot()
    let model = makeModel(
      store: store,
      catalog: browserCatalog,
      mailCatalog: MailCatalogStub(
        scan: MailScanResult(applications: [], isAuthoritative: false),
        runtimeFallback: runtimeFallback
      ),
      targetSnapshot: snapshot
    )
    try model.load()
    store.resetSaved()
    browserCatalog.setScanResult(browserScan)

    try model.rescan()

    let saved = try XCTUnwrap(store.saved.last)
    XCTAssertEqual(saved.mailApplications, persisted.mailApplications)
    XCTAssertEqual(
      saved.targets.filter { $0.routeKind == .mail },
      persisted.targets.filter { $0.routeKind == .mail }
    )
    XCTAssertFalse(try XCTUnwrap(model.mailApplications.first).isAvailable(for: .mail))
    XCTAssertTrue(snapshot.availableSnapshot(for: .mail).targets.isEmpty)
  }

  func testFirefoxRuntimeFallbackModeEditPreservesAuthoritativeProfileMetadata() throws {
    let rawPath =
      "/Users/private-user/Library/Application Support/Firefox/Profiles/authoritative-mode"
    let target = BrowserTarget(
      id: "manual-firefox-mode",
      browserID: Fixtures.firefox.id,
      label: "Authoritative Firefox",
      profileIdentifier: "Authoritative Profile",
      profileDisplayName: "Authoritative Display",
      profileIdentity: rawPath,
      profileLaunchPath: rawPath,
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .manual,
      availability: .available,
      validationError: "Authoritative validation"
    )
    let authoritative = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [Fixtures.firefox],
      targets: [target]
    )
    let scenario = try makeFirefoxRuntimeFallbackModel(config: authoritative)
    let runtimeBefore = try XCTUnwrap(scenario.fallback.targets.first)

    try scenario.model.setTargetMode(id: runtimeBefore.id, mode: .private)

    let saved = try XCTUnwrap(scenario.store.saved.last?.targets.first)
    XCTAssertEqual(saved.id, target.id)
    XCTAssertEqual(saved.mode, .private)
    XCTAssertEqual(saved.profileIdentifier, target.profileIdentifier)
    XCTAssertEqual(saved.profileDisplayName, target.profileDisplayName)
    XCTAssertEqual(saved.profileIdentity, runtimeBefore.profileIdentity)
    XCTAssertEqual(saved.profileLaunchPath, rawPath)
    XCTAssertEqual(saved.validationError, "Authoritative validation")
    XCTAssertEqual(saved.availability, .available)

    let runtimeAfter = try XCTUnwrap(scenario.model.targets.first)
    XCTAssertEqual(runtimeAfter.id, runtimeBefore.id)
    XCTAssertEqual(runtimeAfter.mode, .private)
    XCTAssertNotEqual(runtimeAfter.profileIdentity, rawPath)
    XCTAssertNil(runtimeAfter.profileLaunchPath)
    XCTAssertNil(runtimeAfter.validationError)
    XCTAssertEqual(runtimeAfter.availability, .unavailable)
  }

  func testFirefoxRuntimeFallbackPendingRenamePreservesAuthoritativeMetadata() throws {
    let rawPath =
      "/Users/private-user/Library/Application Support/Firefox/Profiles/pending-rename"
    let pending = Fixtures.pendingFirefoxProfileTarget(
      rawPath: rawPath,
      label: "Pending Firefox",
      sortOrder: 0
    )
    let authoritative = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [Fixtures.firefox],
      targets: [pending]
    )
    let scenario = try makeFirefoxRuntimeFallbackModel(config: authoritative)
    let runtimeID = try XCTUnwrap(scenario.fallback.targets.first?.id)

    try scenario.model.renameTarget(id: runtimeID, label: "Renamed Firefox")

    let saved = try XCTUnwrap(scenario.store.saved.last?.targets.first)
    XCTAssertEqual(saved.id, runtimeID)
    XCTAssertEqual(saved.label, "Renamed Firefox")
    XCTAssertFalse(saved.pendingDefaultMigration)
    XCTAssertEqual(saved.profileIdentifier, pending.profileIdentifier)
    XCTAssertEqual(saved.profileDisplayName, pending.profileDisplayName)
    XCTAssertEqual(saved.profileIdentity, scenario.fallback.targets.first?.profileIdentity)
    XCTAssertEqual(saved.profileLaunchPath, rawPath)
    XCTAssertEqual(saved.validationError, pending.validationError)
    XCTAssertEqual(saved.availability, .available)
  }

  func testFirefoxRuntimeFallbackPendingReorderPreservesAuthoritativeMetadata() throws {
    let rawPath =
      "/Users/private-user/Library/Application Support/Firefox/Profiles/pending-reorder"
    let pending = Fixtures.pendingFirefoxProfileTarget(
      rawPath: rawPath,
      label: "Pending Firefox",
      sortOrder: 0
    )
    let other = BrowserTarget(
      id: "manual-firefox-default",
      browserID: Fixtures.firefox.id,
      label: "Firefox Default",
      profileIdentifier: nil,
      profileDisplayName: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 1,
      origin: .manual,
      availability: .available
    )
    let authoritative = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [Fixtures.firefox],
      targets: [pending, other]
    )
    let scenario = try makeFirefoxRuntimeFallbackModel(config: authoritative)

    try scenario.model.moveTargets(fromOffsets: IndexSet(integer: 0), toOffset: 2)

    let runtimeID = try XCTUnwrap(scenario.fallback.targets.first?.id)
    let saved = try XCTUnwrap(
      scenario.store.saved.last?.targets.first { $0.id == runtimeID }
    )
    XCTAssertEqual(saved.sortOrder, 1)
    XCTAssertFalse(saved.pendingDefaultMigration)
    XCTAssertEqual(saved.profileIdentifier, pending.profileIdentifier)
    XCTAssertEqual(saved.profileDisplayName, pending.profileDisplayName)
    XCTAssertEqual(saved.profileIdentity, scenario.fallback.targets.first?.profileIdentity)
    XCTAssertEqual(saved.profileLaunchPath, rawPath)
    XCTAssertEqual(saved.validationError, pending.validationError)
    XCTAssertEqual(saved.availability, .available)
  }

  func testFirefoxRuntimeFallbackProfileClearPreservesAuthoritativeValidationState() throws {
    let rawPath =
      "/Users/private-user/Library/Application Support/Firefox/Profiles/profile-clear"
    let target = BrowserTarget(
      id: "manual-firefox-profile-clear",
      browserID: Fixtures.firefox.id,
      label: "Firefox Profile",
      profileIdentifier: "Authoritative Profile",
      profileDisplayName: "Authoritative Display",
      profileIdentity: rawPath,
      profileLaunchPath: rawPath,
      mode: .private,
      isEnabled: true,
      sortOrder: 0,
      origin: .manual,
      availability: .available,
      validationError: "Authoritative validation"
    )
    let authoritative = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [Fixtures.firefox],
      targets: [target]
    )
    let scenario = try makeFirefoxRuntimeFallbackModel(config: authoritative)
    let runtimeID = try XCTUnwrap(scenario.fallback.targets.first?.id)

    try scenario.model.setTargetProfile(id: runtimeID, profileIdentifier: nil)

    let saved = try XCTUnwrap(scenario.store.saved.last?.targets.first)
    XCTAssertEqual(saved.id, target.id)
    XCTAssertNil(saved.profileIdentifier)
    XCTAssertNil(saved.profileDisplayName)
    XCTAssertNil(saved.profileIdentity)
    XCTAssertNil(saved.profileLaunchPath)
    XCTAssertEqual(saved.mode, .private)
    XCTAssertEqual(saved.validationError, "Authoritative validation")
    XCTAssertEqual(saved.availability, .available)
  }

  func testFirefoxRuntimeTargetIDCollisionMapsSemanticEditsToOriginalAuthoritativeTarget() throws {
    let cases:
      [(
        name: String,
        apply: (AppModel, RouteTarget.ID) throws -> Void,
        assertFirst: (RouteTarget) -> Void
      )] = [
        (
          "rename",
          { model, id in try model.renameTarget(id: id, label: "Edited First") },
          { XCTAssertEqual($0.label, "Edited First") }
        ),
        (
          "enablement",
          { model, id in try model.setTargetEnabled(id: id, isEnabled: false) },
          { XCTAssertFalse($0.isEnabled) }
        ),
        (
          "mode",
          { model, id in try model.setTargetMode(id: id, mode: .private) },
          { XCTAssertEqual($0.mode, .private) }
        ),
        (
          "profile",
          { model, id in try model.setTargetProfile(id: id, profileIdentifier: nil) },
          {
            XCTAssertNil($0.profileIdentifier)
            XCTAssertNil($0.profileIdentity)
          }
        ),
      ]

    for testCase in cases {
      let collision = Fixtures.firefoxRuntimeIDCollisionConfig()
      let scenario = try makeFirefoxRuntimeFallbackModel(config: collision.config)
      let firstRuntimeID = scenario.fallback.targets[0].id
      XCTAssertEqual(
        firstRuntimeID,
        collision.second.id,
        "\(testCase.name): fixture must exercise exact-ID collision"
      )

      do {
        try testCase.apply(scenario.model, firstRuntimeID)
      } catch {
        XCTFail("\(testCase.name): unexpected edit failure: \(error)")
        continue
      }

      let saved = try XCTUnwrap(scenario.store.saved.last)
      let savedSecond = try XCTUnwrap(
        saved.targets.first { $0.label == collision.second.label }
      )
      let savedFirst = try XCTUnwrap(
        saved.targets.first { $0.id != savedSecond.id }
      )
      XCTAssertNotEqual(savedFirst.id, collision.first.id)
      XCTAssertNotEqual(savedFirst.id, firstRuntimeID)
      if testCase.name == "profile" {
        XCTAssertNil(savedFirst.profileIdentity)
      } else {
        XCTAssertEqual(
          savedFirst.profileIdentity,
          scenario.fallback.targets[0].profileIdentity
        )
      }
      testCase.assertFirst(savedFirst)
      XCTAssertEqual(
        savedSecond,
        collision.second,
        "\(testCase.name): the colliding authoritative target must remain unchanged"
      )
    }
  }

  func testFirefoxRuntimeTargetIDCollisionMapsReorderAndRemovalByExplicitIdentity() throws {
    do {
      let collision = Fixtures.firefoxRuntimeIDCollisionConfig()
      let scenario = try makeFirefoxRuntimeFallbackModel(config: collision.config)

      try scenario.model.moveTargets(fromOffsets: IndexSet(integer: 0), toOffset: 2)

      let saved = try XCTUnwrap(scenario.store.saved.last)
      let savedFirst = try XCTUnwrap(
        saved.targets.first { $0.label == collision.first.label }
      )
      let savedSecond = try XCTUnwrap(
        saved.targets.first { $0.label == collision.second.label }
      )
      XCTAssertNotEqual(savedFirst.id, collision.first.id)
      XCTAssertNotEqual(savedFirst.id, scenario.fallback.targets[0].id)
      XCTAssertEqual(savedFirst.sortOrder, 1)
      XCTAssertEqual(savedSecond.sortOrder, 0)
      XCTAssertEqual(savedFirst.profileIdentity, scenario.fallback.targets[0].profileIdentity)
      XCTAssertEqual(savedSecond.label, collision.second.label)
    }

    do {
      let collision = Fixtures.firefoxRuntimeIDCollisionConfig()
      let scenario = try makeFirefoxRuntimeFallbackModel(config: collision.config)

      try scenario.model.removeManualTarget(id: scenario.fallback.targets[0].id)

      let saved = try XCTUnwrap(scenario.store.saved.last)
      XCTAssertFalse(saved.targets.contains { $0.id == collision.first.id })
      XCTAssertEqual(saved.targets, [collision.second])
    }
  }

  func testLegacyFirefoxFallbackRealStoreSemanticEditsCanonicalizeOnlyForbiddenFields()
    throws
  {
    let cases:
      [(
        name: String,
        apply: (AppModel, RouteTarget.ID) throws -> Void,
        assertEdit: (RouteTarget) -> Void
      )] = [
        (
          "rename",
          { model, id in try model.renameTarget(id: id, label: "Renamed Legacy Firefox") },
          { XCTAssertEqual($0.label, "Renamed Legacy Firefox") }
        ),
        (
          "enablement",
          { model, id in try model.setTargetEnabled(id: id, isEnabled: false) },
          { XCTAssertFalse($0.isEnabled) }
        ),
        (
          "mode",
          { model, id in try model.setTargetMode(id: id, mode: .private) },
          { XCTAssertEqual($0.mode, .private) }
        ),
      ]

    for testCase in cases {
      let scenario = try makeLegacyFirefoxDiskScenario()
      defer { try? FileManager.default.removeItem(at: scenario.directory) }

      XCTAssertNoThrow(try testCase.apply(scenario.model, scenario.runtimeTargetID))

      let reloaded = try scenario.store.load()
      XCTAssertEqual(try reloaded.validatedAndMigrated(), reloaded)
      let edited = try XCTUnwrap(
        reloaded.targets.first { $0.label != "Collision Target" },
        testCase.name
      )
      testCase.assertEdit(edited)
      assertLegacyFirefoxCanonicalization(
        edited,
        originalRuntimeTargetID: scenario.runtimeTargetID,
        file: #filePath,
        line: #line
      )

      let collision = try XCTUnwrap(
        reloaded.targets.first { $0.label == "Collision Target" },
        testCase.name
      )
      XCTAssertEqual(collision.id, LegacyFirefoxDiskFixture.collidingTargetID, testCase.name)
      XCTAssertEqual(collision.validationError, "Collision validation", testCase.name)

      let document = try persistedDocument(in: scenario.directory)
      XCTAssertFalse(document.contains(LegacyFirefoxDiskFixture.rawTargetID), testCase.name)
      XCTAssertFalse(document.contains(LegacyFirefoxDiskFixture.rawProfilePath), testCase.name)
      XCTAssertFalse(document.contains("private-user"), testCase.name)
      XCTAssertFalse(document.contains("profileLaunchPath"), testCase.name)
    }
  }

  func testLegacyFirefoxFallbackRealStoreReorderAndRemovalPersistThroughIDCollision() throws {
    do {
      let scenario = try makeLegacyFirefoxDiskScenario()
      defer { try? FileManager.default.removeItem(at: scenario.directory) }

      try scenario.model.moveTargets(fromOffsets: IndexSet(integer: 0), toOffset: 2)

      let reloaded = try scenario.store.load()
      XCTAssertEqual(try reloaded.validatedAndMigrated(), reloaded)
      let edited = try XCTUnwrap(
        reloaded.targets.first { $0.label == "Legacy Firefox" }
      )
      let collision = try XCTUnwrap(
        reloaded.targets.first { $0.label == "Collision Target" }
      )
      XCTAssertEqual(edited.sortOrder, 1)
      XCTAssertEqual(collision.sortOrder, 0)
      assertLegacyFirefoxCanonicalization(
        edited,
        originalRuntimeTargetID: scenario.runtimeTargetID,
        file: #filePath,
        line: #line
      )
      XCTAssertEqual(collision.id, LegacyFirefoxDiskFixture.collidingTargetID)
    }

    do {
      let scenario = try makeLegacyFirefoxDiskScenario()
      defer { try? FileManager.default.removeItem(at: scenario.directory) }

      try scenario.model.removeManualTarget(id: scenario.runtimeTargetID)

      let reloaded = try scenario.store.load()
      XCTAssertEqual(try reloaded.validatedAndMigrated(), reloaded)
      XCTAssertEqual(reloaded.targets.map(\.label), ["Collision Target"])
      XCTAssertEqual(reloaded.targets.first?.id, LegacyFirefoxDiskFixture.collidingTargetID)
    }
  }

  func testLegacyFirefoxFallbackRealStoreProfileClearDoesNotRestoreFallbackIdentity() throws {
    let scenario = try makeLegacyFirefoxDiskScenario()
    defer { try? FileManager.default.removeItem(at: scenario.directory) }

    try scenario.model.setTargetProfile(
      id: scenario.runtimeTargetID,
      profileIdentifier: nil
    )

    let reloaded = try scenario.store.load()
    XCTAssertEqual(try reloaded.validatedAndMigrated(), reloaded)
    let edited = try XCTUnwrap(
      reloaded.targets.first { $0.label == "Legacy Firefox" }
    )
    XCTAssertNotEqual(edited.id, LegacyFirefoxDiskFixture.rawTargetID)
    XCTAssertNotEqual(edited.id, LegacyFirefoxDiskFixture.collidingTargetID)
    XCTAssertNil(edited.profileIdentifier)
    XCTAssertNil(edited.profileDisplayName)
    XCTAssertNil(edited.profileIdentity)
    XCTAssertEqual(edited.validationError, "Authoritative validation")
    XCTAssertEqual(edited.availability, .available)
  }

  func testLegacyDetectedNameOnlyFirefoxProfilesPersistEditsWithSafeShape() throws {
    let safeID = BrowserCatalog.targetID(
      bundleIdentifier: Fixtures.firefox.id,
      profileIdentifier: "Legacy Name Only",
      mode: .normal
    )
    let forbiddenID = "/Users/private-user/Firefox/Profiles/legacy-name-only"

    for legacyID in [safeID, forbiddenID] {
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "pick-via-name-only-firefox-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      defer { try? FileManager.default.removeItem(at: directory) }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(
        LegacyFirefoxDiskFixture.nameOnlyAvailableDetectedDocument(targetID: legacyID).utf8
      ).write(to: directory.appending(path: "PickViaConfig.json"), options: .atomic)

      let store = JSONConfigStore(directory: directory)
      let model = makeModel(
        store: store,
        catalog: BrowserCatalogStub(
          scanResult: BrowserScanResult(browsers: [], warnings: [], isAuthoritative: false)
        )
      )
      try model.load()

      let runtimeTarget = try XCTUnwrap(
        model.targets.first { $0.profileIdentifier == "Legacy Name Only" }
      )
      XCTAssertEqual(runtimeTarget.availability, .unavailable)

      try model.renameTarget(id: runtimeTarget.id, label: "Renamed Name Only")
      try model.setTargetEnabled(id: runtimeTarget.id, isEnabled: false)
      try model.moveTargets(fromOffsets: IndexSet(integer: 0), toOffset: 2)

      let reloaded = try store.load()
      XCTAssertEqual(try reloaded.validatedAndMigrated(), reloaded)
      let edited = try XCTUnwrap(
        reloaded.targets.first { $0.profileIdentifier == "Legacy Name Only" }
      )
      XCTAssertEqual(edited.id, safeID)
      XCTAssertEqual(edited.label, "Renamed Name Only")
      XCTAssertFalse(edited.isEnabled)
      XCTAssertEqual(edited.sortOrder, 1)
      XCTAssertEqual(edited.origin, .detected)
      XCTAssertEqual(edited.availability, .unavailable)
      XCTAssertNil(edited.profileIdentity)
      XCTAssertNil(edited.profileLaunchPath)
      XCTAssertNil(edited.validationError)

      let document = try persistedDocument(in: directory)
      XCTAssertFalse(document.contains(forbiddenID))
      XCTAssertFalse(document.contains("private-user"))
      XCTAssertFalse(document.contains("profileLaunchPath"))
      XCTAssertFalse(document.contains("validationError"))
    }
  }

  func testPathShapedDetectedFirefoxNamePersistsAsUnavailableOpaqueProfile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "pick-via-path-shaped-firefox-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encodedPath = "%252FUsers%252Fprivate-user%252FFirefox%252FProfiles%252Flegacy"
    try Data(
      LegacyFirefoxDiskFixture.pathShapedNameOnlyDetectedDocument(
        encodedProfilePath: encodedPath
      ).utf8
    ).write(to: directory.appending(path: "PickViaConfig.json"), options: .atomic)

    let store = JSONConfigStore(directory: directory)
    let model = makeModel(
      store: store,
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(browsers: [], warnings: [], isAuthoritative: false)
      )
    )
    try model.load()
    let runtimeTarget = try XCTUnwrap(
      model.targets.first { $0.label == "Path-shaped Profile" }
    )
    XCTAssertNotEqual(runtimeTarget.id, "org.mozilla.firefox||normal")
    XCTAssertEqual(runtimeTarget.availability, .unavailable)

    try model.renameTarget(id: runtimeTarget.id, label: "Saved Path-shaped Profile")

    let reloaded = try store.load()
    let saved = try XCTUnwrap(
      reloaded.targets.first { $0.label == "Saved Path-shaped Profile" }
    )
    XCTAssertNotEqual(saved.id, "org.mozilla.firefox||normal")
    XCTAssertEqual(saved.availability, .unavailable)
    XCTAssertNil(saved.profileIdentifier)
    XCTAssertNil(saved.profileDisplayName)
    XCTAssertTrue(FirefoxProfileIdentity.isOpaqueIdentifier(try XCTUnwrap(saved.profileIdentity)))
    XCTAssertEqual(
      saved.id,
      BrowserCatalog.targetID(
        bundleIdentifier: Fixtures.firefox.id,
        profileIdentifier: saved.profileIdentity,
        mode: .normal
      )
    )
    XCTAssertEqual(
      try XCTUnwrap(reloaded.targets.first { $0.label == "Firefox Default" }).id,
      "org.mozilla.firefox||normal"
    )

    let document = try persistedDocument(in: directory)
    XCTAssertFalse(document.contains("private-user"))
    XCTAssertFalse(document.contains(encodedPath))
    XCTAssertFalse(document.contains("profileLaunchPath"))
  }

  func testDetectedPathShapedFirefoxProfileClearPreservesUnresolvedProfileEvidence() throws {
    let encodedPath = "%252FUsers%252Fprivate-user%252FFirefox%252FProfiles%252Flegacy"

    for includeBrowserDefault in [false, true] {
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "pick-via-detected-profile-clear-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      defer { try? FileManager.default.removeItem(at: directory) }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(
        LegacyFirefoxDiskFixture.pathShapedNameOnlyDetectedDocument(
          encodedProfilePath: encodedPath,
          includeBrowserDefault: includeBrowserDefault
        ).utf8
      ).write(to: directory.appending(path: "PickViaConfig.json"), options: .atomic)

      let store = JSONConfigStore(directory: directory)
      let model = makeModel(
        store: store,
        catalog: BrowserCatalogStub(
          scanResult: BrowserScanResult(browsers: [], warnings: [], isAuthoritative: false)
        )
      )
      try model.load()
      let runtimeTarget = try XCTUnwrap(
        model.targets.first { $0.label == "Path-shaped Profile" }
      )
      XCTAssertNil(runtimeTarget.profileIdentifier)
      XCTAssertNil(runtimeTarget.profileDisplayName)
      XCTAssertEqual(runtimeTarget.availability, .unavailable)

      try model.setTargetProfile(id: runtimeTarget.id, profileIdentifier: nil)

      let reloaded = try store.load()
      XCTAssertEqual(try reloaded.validatedAndMigrated(), reloaded)
      let saved = try XCTUnwrap(
        reloaded.targets.first { $0.label == "Path-shaped Profile" }
      )
      XCTAssertNotEqual(saved.id, "org.mozilla.firefox||normal")
      XCTAssertEqual(saved.origin, .detected)
      XCTAssertEqual(saved.availability, .unavailable)
      XCTAssertNil(saved.profileIdentifier)
      XCTAssertNil(saved.profileDisplayName)
      XCTAssertTrue(
        FirefoxProfileIdentity.isOpaqueIdentifier(try XCTUnwrap(saved.profileIdentity))
      )
      XCTAssertEqual(
        saved.id,
        BrowserCatalog.targetID(
          bundleIdentifier: Fixtures.firefox.id,
          profileIdentifier: saved.profileIdentity,
          mode: .normal
        )
      )

      if includeBrowserDefault {
        let collisionOwner = try XCTUnwrap(
          reloaded.targets.first { $0.label == "Firefox Default" }
        )
        XCTAssertEqual(collisionOwner.id, "org.mozilla.firefox||normal")
        XCTAssertEqual(collisionOwner.origin, .detected)
        XCTAssertEqual(collisionOwner.availability, .available)
        XCTAssertNil(collisionOwner.profileIdentifier)
        XCTAssertNil(collisionOwner.profileDisplayName)
        XCTAssertNil(collisionOwner.profileIdentity)
      } else {
        XCTAssertEqual(reloaded.targets.count, 1)
      }

      let document = try persistedDocument(in: directory)
      XCTAssertFalse(document.contains(encodedPath))
      XCTAssertFalse(document.contains("private-user"))
      XCTAssertFalse(document.contains("profileLaunchPath"))
    }
  }

  func testDetectedPathShapedFirefoxProfileClearRetriesAfterFailedCanonicalSave() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "pick-via-detected-profile-clear-retry-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encodedPath = "%252FUsers%252Fprivate-user%252FFirefox%252FProfiles%252Flegacy"
    try Data(
      LegacyFirefoxDiskFixture.pathShapedNameOnlyDetectedDocument(
        encodedProfilePath: encodedPath
      ).utf8
    ).write(to: directory.appending(path: "PickViaConfig.json"), options: .atomic)

    let diskStore = JSONConfigStore(directory: directory)
    let failOnceStore = FailOnceConfigStore(
      wrapping: diskStore,
      error: TestError.denied
    )
    let model = makeModel(
      store: failOnceStore,
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(browsers: [], warnings: [], isAuthoritative: false)
      )
    )
    try model.load()
    let runtimeTarget = try XCTUnwrap(
      model.targets.first { $0.label == "Path-shaped Profile" }
    )
    let runtimeBeforeSave = model.config

    XCTAssertThrowsError(
      try model.setTargetProfile(id: runtimeTarget.id, profileIdentifier: nil)
    )
    XCTAssertEqual(model.config, runtimeBeforeSave)
    XCTAssertTrue(try persistedDocument(in: directory).contains(encodedPath))

    try model.setTargetProfile(id: runtimeTarget.id, profileIdentifier: nil)

    let reloaded = try diskStore.load()
    XCTAssertEqual(try reloaded.validatedAndMigrated(), reloaded)
    let saved = try XCTUnwrap(
      reloaded.targets.first { $0.label == "Path-shaped Profile" }
    )
    XCTAssertNotEqual(saved.id, "org.mozilla.firefox||normal")
    XCTAssertEqual(saved.availability, .unavailable)
    XCTAssertTrue(
      FirefoxProfileIdentity.isOpaqueIdentifier(try XCTUnwrap(saved.profileIdentity))
    )
    XCTAssertEqual(
      try XCTUnwrap(reloaded.targets.first { $0.label == "Firefox Default" }).id,
      "org.mozilla.firefox||normal"
    )
    XCTAssertFalse(try persistedDocument(in: directory).contains(encodedPath))
  }

  func testDetectedFirefoxCanonicalIDCollisionsPersistAcrossSemanticSaves() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "pick-via-detected-firefox-collisions-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let rawIdentityPath = "/Users/private-user/Firefox/Profiles/raw-collision"
    let rawIdentity = FirefoxProfileIdentity.identifier(
      for: URL(fileURLWithPath: rawIdentityPath, isDirectory: true)
    )
    let rawCanonicalID = BrowserCatalog.targetID(
      bundleIdentifier: Fixtures.firefox.id,
      profileIdentifier: rawIdentity,
      mode: .normal
    )
    let nameCanonicalID = BrowserCatalog.targetID(
      bundleIdentifier: Fixtures.firefox.id,
      profileIdentifier: "Legacy Name Collision",
      mode: .private
    )
    try Data(
      LegacyFirefoxDiskFixture.detectedCanonicalCollisionDocument(
        rawIdentityPath: rawIdentityPath,
        rawIdentityCanonicalTargetID: rawCanonicalID,
        nameOnlyCanonicalTargetID: nameCanonicalID
      ).utf8
    ).write(to: directory.appending(path: "PickViaConfig.json"), options: .atomic)

    let store = JSONConfigStore(directory: directory)
    let model = makeModel(
      store: store,
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(browsers: [], warnings: [], isAuthoritative: false)
      )
    )
    try model.load()
    let rawRuntimeID = try XCTUnwrap(
      model.targets.first { $0.label == "Raw Identity Profile" }
    ).id
    let nameRuntimeID = try XCTUnwrap(
      model.targets.first { $0.label == "Name Only Profile" }
    ).id

    try model.renameTarget(id: rawRuntimeID, label: "Renamed Raw Identity")
    try model.setTargetEnabled(id: nameRuntimeID, isEnabled: false)
    try model.moveTargets(fromOffsets: IndexSet(integer: 0), toOffset: 5)
    try model.removeManualTarget(id: "unrelated-removable")

    let reloaded = try store.load()
    XCTAssertEqual(try reloaded.validatedAndMigrated(), reloaded)
    let raw = try XCTUnwrap(reloaded.targets.first { $0.label == "Renamed Raw Identity" })
    let name = try XCTUnwrap(reloaded.targets.first { $0.label == "Name Only Profile" })
    let rawOwner = try XCTUnwrap(reloaded.targets.first { $0.label == "Raw Collision Owner" })
    let nameOwner = try XCTUnwrap(reloaded.targets.first { $0.label == "Name Collision Owner" })
    XCTAssertNotEqual(raw.id, rawCanonicalID)
    XCTAssertNotEqual(name.id, nameCanonicalID)
    XCTAssertNotEqual(raw.id, name.id)
    XCTAssertTrue(FirefoxProfileIdentity.isOpaqueIdentifier(try XCTUnwrap(raw.profileIdentity)))
    XCTAssertTrue(FirefoxProfileIdentity.isOpaqueIdentifier(try XCTUnwrap(name.profileIdentity)))
    XCTAssertEqual(name.availability, .unavailable)
    XCTAssertFalse(name.isEnabled)
    XCTAssertEqual(rawOwner.id, rawCanonicalID)
    XCTAssertEqual(rawOwner.validationError, "Raw collision validation")
    XCTAssertEqual(nameOwner.id, nameCanonicalID)
    XCTAssertEqual(nameOwner.validationError, "Name collision validation")
    XCTAssertFalse(reloaded.targets.contains { $0.id == "unrelated-removable" })

    let document = try persistedDocument(in: directory)
    XCTAssertFalse(document.contains("private-user"))
    XCTAssertFalse(document.contains("profileLaunchPath"))
  }

  func testSchemaTwoFirefoxProfileChangePersistsSelectedSafeMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "pick-via-schema-two-firefox-profile-change-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selectedIdentity = FirefoxProfileIdentity.identifier(
      for: URL(fileURLWithPath: "/Firefox/Profiles/selected", isDirectory: true)
    )
    let encodedLegacyPath = "%252FUsers%252Fprivate-user%252FFirefox%252FProfiles%252Flegacy"
    try Data(
      LegacyFirefoxDiskFixture.firefoxProfileChangeDocument(
        selectedIdentity: selectedIdentity,
        encodedLegacyPath: encodedLegacyPath
      ).utf8
    ).write(to: directory.appending(path: "PickViaConfig.json"), options: .atomic)

    let store = JSONConfigStore(directory: directory)
    let model = makeModel(
      store: store,
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(
          browsers: [
            DiscoveredBrowser(
              application: Fixtures.firefox,
              profiles: [
                DiscoveredProfile(
                  identifier: selectedIdentity,
                  displayName: "Selected Display",
                  directoryURL: nil,
                  launchIdentifier: "selected-launch"
                )
              ]
            )
          ],
          warnings: [],
          isAuthoritative: true
        ),
        reconciler: { $0 }
      )
    )
    try model.load()

    try model.setTargetProfile(
      id: "manual-profile-change",
      profileIdentifier: "selected-launch"
    )

    let reloaded = try store.load()
    XCTAssertEqual(try reloaded.validatedAndMigrated(), reloaded)
    let manual = try XCTUnwrap(reloaded.targets.first { $0.id == "manual-profile-change" })
    XCTAssertEqual(manual.profileIdentifier, "selected-launch")
    XCTAssertEqual(manual.profileDisplayName, "Selected Display")
    XCTAssertEqual(manual.profileIdentity, selectedIdentity)
    XCTAssertEqual(manual.mode, .private)
    XCTAssertNil(manual.profileLaunchPath)
    XCTAssertNil(manual.validationError)

    let document = try persistedDocument(in: directory)
    XCTAssertFalse(document.contains("private-user"))
    XCTAssertFalse(document.contains(encodedLegacyPath))
    XCTAssertFalse(document.contains("profileLaunchPath"))
  }

  func testRealStoreProfileChangeStillUsesSelectedAuthoritativeProfileMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "pick-via-profile-change-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let manual = BrowserTarget(
      id: "manual-edit",
      browserID: Fixtures.chrome.id,
      label: "Manual",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      mode: .normal,
      isEnabled: true,
      sortOrder: 30,
      origin: .manual,
      availability: .available
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: Fixtures.profileEditConfig.browsers,
      targets: Fixtures.profileEditConfig.targets + [manual]
    )
    let store = JSONConfigStore(directory: directory)
    try store.save(config)
    let model = makeModel(store: store)
    try model.load()

    try model.setTargetProfile(id: manual.id, profileIdentifier: "Profile 2")

    let reloaded = try store.load()
    let edited = try XCTUnwrap(reloaded.targets.first { $0.id == manual.id })
    XCTAssertEqual(edited.profileIdentifier, "Profile 2")
    XCTAssertEqual(edited.profileDisplayName, "Personal")
    XCTAssertEqual(edited.mode, .normal)
  }

  func testLoadAppliesMailRuntimeFallbackBeforeEitherDiscoveryPass() throws {
    let unavailableMail = Fixtures.copy(
      Fixtures.appleMail,
      mailIsAvailable: false
    )
    let fallback = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [Fixtures.chrome, unavailableMail],
      targets: Fixtures.webAndMailConfig.targets
    )
    let mailCatalog = MailCatalogStub(
      scan: MailScanResult(applications: [], isAuthoritative: false),
      runtimeFallback: fallback
    )
    let browserCatalog = BrowserCatalogStub(
      scanResult: BrowserScanResult(
        browsers: [],
        warnings: [],
        isAuthoritative: false
      )
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.webAndMailConfig),
      catalog: browserCatalog,
      mailCatalog: mailCatalog
    )

    try model.load()

    XCTAssertEqual(mailCatalog.runtimeFallbackInputs, [Fixtures.webAndMailConfig])
    XCTAssertEqual(browserCatalog.reconcileInputs, [])
    XCTAssertEqual(model.config, fallback)
    XCTAssertFalse(try XCTUnwrap(model.mailApplications.first).isAvailable(for: .mail))
  }

  func testLoadPublishesOneFinalSnapshotContainingBothRouteKinds() throws {
    let snapshot = MutableTargetSnapshot()
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.browserConfig),
      mailCatalog: .authoritative([Fixtures.appleMailDiscovery]),
      targetSnapshot: snapshot
    )

    try model.load()

    XCTAssertFalse(snapshot.availableSnapshot(for: .web).targets.isEmpty)
    XCTAssertEqual(
      snapshot.availableSnapshot(for: .mail).targets.map(\.id),
      [Fixtures.appleMailTarget.id]
    )
  }

  func testRecoveredCorruptionPublishesVisibleRecoveryState() throws {
    let store = ConfigStoreStub(
      config: .initial,
      loadOutcome: .recoveredCorruption(.initial)
    )
    let model = makeModel(store: store)

    try model.load()

    XCTAssertEqual(model.configurationRecovery, .recoveredCorruption)
    XCTAssertNotNil(model.configurationRecoveryMessage)
    XCTAssertNil(model.errorMessage)
  }

  func testValidURLDoesNotClearPersistentConfigurationRecoveryMessage() throws {
    let routing = RoutingSpy()
    let model = makeModel(
      store: ConfigStoreStub(
        config: .initial,
        loadOutcome: .recoveredCorruption(.initial)
      ),
      routing: routing
    )
    try model.load()

    model.accept(url: URL(string: "https://example.com/recovered")!)

    XCTAssertEqual(routing.acceptedURLs, [URL(string: "https://example.com/recovered")!])
    XCTAssertNotNil(model.configurationRecoveryMessage)
  }

  func testInvalidStartupReconciliationPreservesLastValidConfigAndSnapshot() throws {
    let valid = Fixtures.editableConfig
    let invalid = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: valid.browsers,
      targets: [valid.targets[0], valid.targets[0]]
    )
    let store = ConfigStoreStub(config: valid)
    let snapshot = MutableTargetSnapshot()
    let catalog = BrowserCatalogStub(
      discovered: [Fixtures.discoveredChrome],
      reconciled: invalid
    )
    let model = makeModel(store: store, catalog: catalog, targetSnapshot: snapshot)

    try model.load()

    XCTAssertEqual(model.config, valid)
    XCTAssertEqual(snapshot.availableSnapshot(for: .web).targets.map(\.id), ["work"])
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertNotNil(model.errorMessage)
  }

  func testStartupReadOnlySaveFailurePublishesPathFreeUnavailableFirefoxFallback() throws {
    try assertStartupFirefoxMigrationSaveFailure(
      CocoaError(.fileWriteNoPermission)
    )
  }

  func testStartupDiskFullSaveFailurePublishesPathFreeUnavailableFirefoxFallback() throws {
    try assertStartupFirefoxMigrationSaveFailure(
      CocoaError(.fileWriteOutOfSpace)
    )
  }

  func testConfigurationReadFailureDoesNotPublishOrOverwriteDefaults() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig, loadOutcome: .failure(.readFailed))
    let catalog = BrowserCatalogStub(discovered: [Fixtures.discoveredChrome])
    let model = makeModel(store: store, catalog: catalog)

    try model.load()

    XCTAssertEqual(model.config, .initial)
    XCTAssertEqual(model.configurationRecovery, .loadFailed)
    XCTAssertTrue(catalog.reconcileInputs.isEmpty)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testTransientDiscoveryFailurePreservesCurrentAvailability() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let catalog = BrowserCatalogStub(
      scanResult: BrowserScanResult(browsers: [], warnings: [], isAuthoritative: false)
    )
    let model = makeModel(store: store, catalog: catalog)

    try model.load()

    XCTAssertEqual(model.config, Fixtures.editableConfig)
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertNotNil(model.errorMessage)
  }

  func testNonAuthoritativeRescanPreservesBrowserSettingsIssueSummary() throws {
    let discovered = Fixtures.installedBrowser(
      "com.google.Chrome", status: .accessRequired)
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [discovered.application],
      targets: []
    )
    let catalog = BrowserCatalogStub(
      reconciled: config,
      scanResult: BrowserScanResult(
        browsers: [discovered],
        profileAccessIssues: [
          .accessRequired(bundleIdentifier: discovered.application.bundleIdentifier)
        ]
      )
    )
    let model = makeModel(
      store: ConfigStoreStub(config: config),
      catalog: catalog
    )
    try model.load()
    XCTAssertEqual(model.browserSettingsIssueSummary.accessIssueBrowserCount, 1)

    catalog.setScanResult(
      BrowserScanResult(
        browsers: [], profileAccessIssues: [], isAuthoritative: false)
    )
    try model.rescan()

    XCTAssertEqual(model.browserSettingsIssueSummary.accessIssueBrowserCount, 1)
  }

  func testTargetedGrantClearsAccessWarningBeforeFullRescan() throws {
    let required = Fixtures.installedBrowser(
      "com.google.Chrome", status: .accessRequired)
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.editableConfig,
      scanResult: BrowserScanResult(
        browsers: [required],
        profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
      ),
      targeted: ["com.google.Chrome": Fixtures.discoveredChromeWithProfiles]
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.editableConfig),
      catalog: catalog,
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()
    XCTAssertEqual(model.browserSettingsIssueSummary.accessIssueBrowserCount, 1)

    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )

    XCTAssertEqual(model.browserSettingsIssueSummary.accessIssueBrowserCount, 0)
  }

  func testTargetedGrantKeepsPresentProfileOutOfMissingWarningUntilFinishRescan() throws {
    let required = Fixtures.installedBrowser(
      "com.google.Chrome", status: .accessRequired)
    let unavailableWork = BrowserTarget(
      id: "work",
      browserID: required.application.id,
      label: "Work",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .unavailable
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [required.application],
      targets: [unavailableWork]
    )
    let store = ConfigStoreStub(config: config)
    let catalog = BrowserCatalogStub(
      reconciled: config,
      scanResult: BrowserScanResult(
        browsers: [required],
        profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
      ),
      targeted: ["com.google.Chrome": Fixtures.discoveredChrome]
    )
    let model = makeModel(
      store: store,
      catalog: catalog,
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()
    store.resetSaved()

    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )

    XCTAssertEqual(
      model.browserSettingsIssueSummary,
      .init(accessIssueBrowserCount: 0, missingEnabledProfileCount: 0)
    )
    model.closeProfileAccess()

    XCTAssertEqual(
      model.browserSettingsIssueSummary,
      .init(accessIssueBrowserCount: 0, missingEnabledProfileCount: 0)
    )
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertEqual(model.config, config)
  }

  func testTargetedGrantMarksOnlyGenuinelyAbsentProfileMissingBeforeFinishRescan() throws {
    let required = Fixtures.installedBrowser(
      "com.google.Chrome", status: .accessRequired)
    let unavailableWork = BrowserTarget(
      id: "work",
      browserID: required.application.id,
      label: "Work",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .unavailable
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [required.application],
      targets: [unavailableWork]
    )
    let targetedWithoutWork = DiscoveredBrowser(
      application: required.application,
      profiles: [
        DiscoveredProfile(identifier: "Profile 2", displayName: "Personal", directoryURL: nil)
      ],
      metadataStatus: .loaded
    )
    let catalog = BrowserCatalogStub(
      reconciled: config,
      scanResult: BrowserScanResult(
        browsers: [required],
        profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
      ),
      targeted: ["com.google.Chrome": targetedWithoutWork]
    )
    let model = makeModel(
      store: ConfigStoreStub(config: config),
      catalog: catalog,
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()

    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )

    XCTAssertEqual(
      model.browserSettingsIssueSummary,
      .init(accessIssueBrowserCount: 0, missingEnabledProfileCount: 1)
    )
  }

  func testTargetedGrantAccessFailureStaysAccessOnlyWithoutMissingDoubleCount() throws {
    let required = Fixtures.installedBrowser(
      "com.google.Chrome", status: .accessRequired)
    let unavailableWork = BrowserTarget(
      id: "work",
      browserID: required.application.id,
      label: "Work",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .unavailable
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [required.application],
      targets: [unavailableWork]
    )
    let catalog = BrowserCatalogStub(
      reconciled: config,
      scanResult: BrowserScanResult(
        browsers: [required],
        profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
      )
    )
    let model = makeModel(
      store: ConfigStoreStub(config: config),
      catalog: catalog,
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()

    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )

    XCTAssertEqual(
      model.browserSettingsIssueSummary,
      .init(accessIssueBrowserCount: 1, missingEnabledProfileCount: 0)
    )
  }

  func testRescanReconcilesAndPersistsConfiguration() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let reconciled = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: Fixtures.editableConfig.browsers,
      targets: Fixtures.editableConfig.targets.map {
        $0.id == "work" ? Fixtures.copy($0, label: "Reconciled") : $0
      }
    )
    let catalog = BrowserCatalogStub(discovered: [], reconciled: reconciled)
    let model = makeModel(store: store, catalog: catalog)
    try model.load()
    store.resetSaved()
    catalog.resetReconcileInputs()

    try model.rescan()

    XCTAssertEqual(model.config, reconciled)
    XCTAssertEqual(catalog.reconcileInputs, [reconciled])
    XCTAssertEqual(store.saved, [reconciled])
  }

  func testRescanMailApplicationsDoesNotRescanOrChangeBrowserState() throws {
    let store = ConfigStoreStub(config: Fixtures.webAndMailConfig)
    let browserCatalog = BrowserCatalogStub(
      scanResult: BrowserScanResult(
        browsers: [],
        warnings: [],
        isAuthoritative: false
      )
    )
    let mailCatalog = MailCatalogStub.authoritative([Fixtures.appleMailDiscovery])
    let model = makeModel(
      store: store,
      catalog: browserCatalog,
      mailCatalog: mailCatalog
    )
    try model.load()
    browserCatalog.resetScanCalls()
    mailCatalog.setScan(
      MailScanResult(
        applications: [Fixtures.outlookDiscovery],
        isAuthoritative: true
      )
    )

    try model.rescanMailApplications()

    XCTAssertEqual(browserCatalog.scanResultCallCount, 0)
    XCTAssertEqual(mailCatalog.scanResultCallCount, 2)
    XCTAssertEqual(
      model.targets.filter { $0.routeKind == .web },
      Fixtures.webAndMailConfig.targets.filter { $0.routeKind == .web }
    )
    XCTAssertEqual(
      Set(model.mailTargets.map(\.id)),
      Set(["mailto|com.apple.mail", "mailto|com.microsoft.Outlook"])
    )
  }

  func testMailRescanPreservesBrowserMetadataForDualCapabilityApplication() throws {
    let originalApplication = RoutedApplication(
      id: Fixtures.chrome.id,
      displayName: Fixtures.chrome.displayName,
      bundleIdentifier: Fixtures.chrome.bundleIdentifier,
      capabilities: [
        .browser(family: .chromium, isAvailable: true),
        .mail(isAvailable: true),
      ],
      applicationURL: Fixtures.chrome.applicationURL,
      browserExecutableURL: Fixtures.chrome.browserExecutableURL
    )
    let mailTarget = RouteTarget(
      id: RouteTarget.mailID(bundleIdentifier: originalApplication.bundleIdentifier),
      applicationID: originalApplication.id,
      label: "Chrome Mail",
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available,
      capability: .mail
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [originalApplication],
      targets: Fixtures.editableConfig.targets + [mailTarget]
    )
    let mailCatalog = MailCatalogStub.nonAuthoritative
    let model = makeModel(
      store: ConfigStoreStub(config: config),
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(
          browsers: [],
          warnings: [],
          isAuthoritative: false
        )
      ),
      mailCatalog: mailCatalog
    )
    try model.load()
    let browserBefore = try XCTUnwrap(model.browsers.first)
    let webTargetsBefore = model.targets.filter { $0.routeKind == .web }
    mailCatalog.setScan(
      MailScanResult(
        applications: [
          DiscoveredMailApplication(
            bundleIdentifier: originalApplication.bundleIdentifier,
            displayName: "Mail Discovery Alias",
            applicationURL: URL(fileURLWithPath: "/Applications/Mail Discovery Alias.app")
          )
        ],
        isAuthoritative: true
      )
    )

    try model.rescanMailApplications()

    XCTAssertEqual(try XCTUnwrap(model.browsers.first), browserBefore)
    XCTAssertEqual(
      model.targets.filter { $0.routeKind == .web },
      webTargetsBefore
    )
  }

  func testMailRescanFailurePreservesConfigurationAndShowsMailError() throws {
    let store = ConfigStoreStub(config: Fixtures.webAndMailConfig)
    let model = makeModel(store: store, mailCatalog: .nonAuthoritative)
    try model.load()
    let before = model.config

    try model.rescanMailApplications()

    XCTAssertEqual(model.config, before)
    XCTAssertEqual(
      model.mailErrorMessage,
      "Mail application discovery could not be completed. Existing choices were preserved."
    )
  }

  func testChooserMailSettingsRescanDefersRefreshUntilSettingsClose() throws {
    let routing = RoutingSpy()
    let mailCatalog = MailCatalogStub.authoritative([Fixtures.appleMailDiscovery])
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.webAndMailConfig),
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(
          browsers: [],
          warnings: [],
          isAuthoritative: false
        )
      ),
      mailCatalog: mailCatalog,
      routing: routing
    )
    try model.load()
    mailCatalog.setScan(
      MailScanResult(
        applications: [Fixtures.appleMailDiscovery, Fixtures.outlookDiscovery],
        isAuthoritative: true
      )
    )
    let navigation = SettingsNavigation()
    let settingsHandler = AppComposition.makeChooserSettingsHandler(
      navigation: navigation,
      openSettings: {},
      chooserSettingsDidOpen: { model.chooserSettingsDidOpen(for: $0) }
    )
    let chooser = ChooserPanelController(openSettings: settingsHandler)

    chooser.showSettings(for: .mail)
    try model.rescanMailApplications()

    XCTAssertEqual(navigation.destination, .mail)
    XCTAssertEqual(routing.refreshCallCount, 0)

    model.settingsDidClose()

    XCTAssertEqual(routing.refreshCallCount, 1)
  }

  func testWebChooserSettingsDefersMailRescanRefreshUntilSettingsClose() throws {
    let routing = RoutingSpy()
    let mailCatalog = MailCatalogStub.authoritative([Fixtures.appleMailDiscovery])
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.webAndMailConfig),
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(
          browsers: [],
          warnings: [],
          isAuthoritative: false
        )
      ),
      mailCatalog: mailCatalog,
      routing: routing
    )
    try model.load()
    mailCatalog.setScan(
      MailScanResult(
        applications: [Fixtures.appleMailDiscovery, Fixtures.outlookDiscovery],
        isAuthoritative: true
      )
    )
    let navigation = SettingsNavigation()
    let settingsHandler = AppComposition.makeChooserSettingsHandler(
      navigation: navigation,
      openSettings: {},
      chooserSettingsDidOpen: { model.chooserSettingsDidOpen(for: $0) }
    )
    let chooser = ChooserPanelController(openSettings: settingsHandler)

    chooser.showSettings(for: .web)
    try model.rescanMailApplications()

    XCTAssertEqual(navigation.destination, .browsers)
    XCTAssertEqual(routing.refreshCallCount, 0)

    model.settingsDidClose()

    XCTAssertEqual(routing.refreshCallCount, 1)
  }

  func testMailChooserSettingsDefersBrowserRescanRefreshUntilSettingsClose() throws {
    let routing = RoutingSpy()
    let browserCatalog = BrowserCatalogStub(
      discovered: [Fixtures.discoveredChrome],
      reconciled: Fixtures.webAndMailConfig
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.webAndMailConfig),
      catalog: browserCatalog,
      mailCatalog: .nonAuthoritative,
      routing: routing
    )
    try model.load()
    let navigation = SettingsNavigation()
    let settingsHandler = AppComposition.makeChooserSettingsHandler(
      navigation: navigation,
      openSettings: {},
      chooserSettingsDidOpen: { model.chooserSettingsDidOpen(for: $0) }
    )
    let chooser = ChooserPanelController(openSettings: settingsHandler)

    chooser.showSettings(for: .mail)
    try model.rescan()

    XCTAssertEqual(navigation.destination, .mail)
    XCTAssertEqual(routing.refreshCallCount, 0)

    model.settingsDidClose()

    XCTAssertEqual(routing.refreshCallCount, 1)
  }

  func testWebChooserSettingsDefersBrowserRescanRefreshUntilSettingsClose() throws {
    let routing = RoutingSpy()
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.webAndMailConfig),
      catalog: BrowserCatalogStub(
        discovered: [Fixtures.discoveredChrome],
        reconciled: Fixtures.webAndMailConfig
      ),
      mailCatalog: .nonAuthoritative,
      routing: routing
    )
    try model.load()
    let navigation = SettingsNavigation()
    let settingsHandler = AppComposition.makeChooserSettingsHandler(
      navigation: navigation,
      openSettings: {},
      chooserSettingsDidOpen: { model.chooserSettingsDidOpen(for: $0) }
    )
    let chooser = ChooserPanelController(openSettings: settingsHandler)

    chooser.showSettings(for: .web)
    try model.rescan()

    XCTAssertEqual(navigation.destination, .browsers)
    XCTAssertEqual(routing.refreshCallCount, 0)

    model.settingsDidClose()

    XCTAssertEqual(routing.refreshCallCount, 1)
  }

  func testMailRescanOutsideContextualSettingsRefreshesImmediately() throws {
    let routing = RoutingSpy()
    let mailCatalog = MailCatalogStub.authoritative([Fixtures.appleMailDiscovery])
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.webAndMailConfig),
      mailCatalog: mailCatalog,
      routing: routing
    )
    try model.load()
    mailCatalog.setScan(
      MailScanResult(
        applications: [Fixtures.appleMailDiscovery, Fixtures.outlookDiscovery],
        isAuthoritative: true
      )
    )

    try model.rescanMailApplications()

    XCTAssertEqual(routing.refreshCallCount, 1)
  }

  func testBrowserRescanOutsideContextualSettingsRefreshesImmediately() throws {
    let routing = RoutingSpy()
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.webAndMailConfig),
      catalog: BrowserCatalogStub(
        discovered: [Fixtures.discoveredChrome],
        reconciled: Fixtures.webAndMailConfig
      ),
      mailCatalog: .nonAuthoritative,
      routing: routing
    )
    try model.load()

    try model.rescan()

    XCTAssertEqual(routing.refreshCallCount, 1)
  }

  func testAutomaticWizardContainsOnlyAccessFailuresAndSuppressesAfterSkip() throws {
    let scan = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired),
        Fixtures.installedBrowser("org.mozilla.firefox", status: .accessRevoked),
        Fixtures.installedBrowser("com.microsoft.edgemac", status: .metadataAbsent),
        Fixtures.installedBrowser("com.brave.Browser", status: .metadataDamaged),
      ],
      profileAccessIssues: [
        .accessRequired(bundleIdentifier: "com.google.Chrome"),
        .accessRevoked(bundleIdentifier: "org.mozilla.firefox"),
        .metadataDamaged(bundleIdentifier: "com.brave.Browser"),
      ],
      isAuthoritative: true
    )
    let access = ProfileAccessManagerSpy(
      persistence: ["org.mozilla.firefox": .persistent]
    )
    let model = makeModel(
      catalog: BrowserCatalogStub(scanResult: scan),
      access: access
    )

    try model.load()

    XCTAssertEqual(
      model.profileAccessRows.map(\.bundleIdentifier),
      ["com.google.Chrome", "org.mozilla.firefox"]
    )
    XCTAssertEqual(model.profileAccessRows.map(\.state), [.accessNeeded, .accessRevoked])
    XCTAssertEqual(model.profileAccessRows.map(\.hasStoredGrant), [false, true])
    XCTAssertEqual(model.profileAccessPresentation, .automaticPending)
    XCTAssertTrue(model.shouldAutomaticallyPresentProfileAccess)

    model.skipProfileAccess()

    XCTAssertEqual(model.profileAccessPresentation, .suppressedForProcess)
    XCTAssertFalse(model.shouldAutomaticallyPresentProfileAccess)
  }

  func testCloseSuppressesAutomaticWizardUntilDirectUserRescan() throws {
    let scan = BrowserScanResult(
      browsers: [Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired)],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")],
      isAuthoritative: true
    )
    let catalog = BrowserCatalogStub(scanResult: scan)
    let model = makeModel(catalog: catalog)
    try model.load()
    model.profileAccessDidPresent()

    model.closeProfileAccess()

    XCTAssertEqual(model.profileAccessPresentation, .suppressedForProcess)

    model.profileAccessDidDismiss()
    try model.userRequestedRescan()

    XCTAssertEqual(catalog.scanResultCallCount, 2)
    XCTAssertEqual(model.profileAccessPresentation, .automaticPending)
    XCTAssertTrue(model.shouldAutomaticallyPresentProfileAccess)
  }

  func testManualManagerContainsEveryInstalledNonSafariBrowserWithApprovedCopy() throws {
    let scan = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChromeWithProfiles.profiles
        ),
        Fixtures.installedBrowser("org.mozilla.firefox", status: .metadataDamaged),
        Fixtures.installedBrowser("com.apple.Safari", status: .notApplicable),
      ],
      profileAccessIssues: [.metadataDamaged(bundleIdentifier: "org.mozilla.firefox")],
      isAuthoritative: true
    )
    let access = ProfileAccessManagerSpy(
      persistence: ["com.google.Chrome": .persistent]
    )
    let model = makeModel(
      catalog: BrowserCatalogStub(scanResult: scan),
      access: access
    )
    try model.load()

    XCTAssertEqual(model.profileAccessPresentation, .idle)

    model.openProfileAccessManager()

    XCTAssertEqual(model.profileAccessPresentation, .manualPending)
    XCTAssertEqual(
      model.profileAccessRows.map(\.bundleIdentifier),
      ["com.google.Chrome", "org.mozilla.firefox"]
    )
    XCTAssertEqual(
      model.profileAccessRows.map(\.state),
      [
        .granted(profileCount: 2, persistence: .persistent),
        .metadataDamaged,
      ]
    )
    let chrome = try XCTUnwrap(model.profileAccessRows.first)
    XCTAssertEqual(chrome.displayName, "Google Chrome")
    XCTAssertEqual(chrome.family, .chromium)
    XCTAssertEqual(chrome.expectedRootSuffix, "Library/Application Support/Google/Chrome")
    XCTAssertEqual(chrome.requiredMarker, "Local State")
    XCTAssertTrue(chrome.hasStoredGrant)
  }

  func testFinishEligibilityRequiresAtLeastOneGrantedRow() throws {
    let scan = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser("com.google.Chrome", status: .loaded),
        Fixtures.installedBrowser(
          "org.mozilla.firefox",
          status: .loaded,
          profiles: [
            DiscoveredProfile(identifier: "default", displayName: "Default", directoryURL: nil)
          ]
        ),
      ],
      profileAccessIssues: [],
      isAuthoritative: true
    )
    let access = ProfileAccessManagerSpy(
      persistence: ["org.mozilla.firefox": .currentSessionOnly]
    )
    let model = makeModel(
      catalog: BrowserCatalogStub(scanResult: scan),
      access: access
    )
    try model.load()

    XCTAssertFalse(model.canFinishProfileAccess)

    model.openProfileAccessManager()

    XCTAssertTrue(model.canFinishProfileAccess)
    XCTAssertEqual(
      model.profileAccessRows.last?.state,
      .granted(profileCount: 1, persistence: .currentSessionOnly)
    )
  }

  func testWrongRootDoesNotInstallGrantOrDiscardAnotherGrantedRow() throws {
    let scan = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired),
        Fixtures.installedBrowser("org.mozilla.firefox", status: .accessRequired),
      ],
      profileAccessIssues: [
        .accessRequired(bundleIdentifier: "com.google.Chrome"),
        .accessRequired(bundleIdentifier: "org.mozilla.firefox"),
      ]
    )
    let access = ProfileAccessManagerSpy()
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.editableConfig,
      scanResult: scan,
      targeted: ["com.google.Chrome": Fixtures.discoveredChromeWithProfiles]
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.editableConfig),
      catalog: catalog,
      access: access,
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()
    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )

    try model.grantProfileAccess(
      for: "org.mozilla.firefox",
      root: URL(fileURLWithPath: "/Users/private/wrong-firefox-folder")
    )

    XCTAssertEqual(access.installed.map(\.bundleIdentifier), ["com.google.Chrome"])
    XCTAssertEqual(
      model.profileAccessRows.map(\.state),
      [
        .granted(profileCount: 2, persistence: .persistent),
        .invalidFolder(requiredMarker: "profiles.ini"),
      ]
    )
    XCTAssertTrue(model.canFinishProfileAccess)
    XCTAssertFalse(
      String(describing: model.profileAccessRows).contains("/Users/private")
    )
  }

  func testFailedGrantReplacementKeepsPriorGrantAndRowAuthoritative() throws {
    let scan = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChromeWithProfiles.profiles
        )
      ],
      profileAccessIssues: []
    )
    let access = ProfileAccessManagerSpy(
      persistence: ["com.google.Chrome": .persistent],
      installError: NSError(
        domain: "secret replacement /Users/private/Chrome",
        code: 17
      )
    )
    let model = makeModel(
      catalog: BrowserCatalogStub(scanResult: scan),
      access: access,
      profileRootValidator: profileRootValidator(validRoots: ["/Replacement"])
    )
    try model.load()
    model.openProfileAccessManager()
    let priorRow = try XCTUnwrap(model.profileAccessRows.first)

    XCTAssertThrowsError(
      try model.grantProfileAccess(
        for: "com.google.Chrome",
        root: URL(fileURLWithPath: "/Replacement")
      )
    )

    XCTAssertEqual(model.profileAccessRows.first, priorRow)
    XCTAssertEqual(access.persistence(for: "com.google.Chrome"), .persistent)
    XCTAssertEqual(access.installed.map(\.bundleIdentifier), ["com.google.Chrome"])
    XCTAssertFalse(model.errorMessage?.contains("/Users/private") ?? false)
    XCTAssertFalse(model.errorMessage?.contains("secret replacement") ?? false)
  }

  func testInvalidFolderReplacementRetainsExistingGrantAndFinishEligibility() throws {
    let scan = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChromeWithProfiles.profiles
        )
      ],
      profileAccessIssues: []
    )
    let access = ProfileAccessManagerSpy(
      persistence: ["com.google.Chrome": .persistent]
    )
    let model = makeModel(
      catalog: BrowserCatalogStub(scanResult: scan),
      access: access,
      profileRootValidator: profileRootValidator(validRoots: [])
    )
    try model.load()
    model.openProfileAccessManager()

    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Users/private/wrong-chrome-folder")
    )

    XCTAssertEqual(
      model.profileAccessRows.first?.state,
      .invalidFolder(requiredMarker: "Local State")
    )
    XCTAssertTrue(model.profileAccessRows.first?.hasStoredGrant == true)
    XCTAssertTrue(model.canFinishProfileAccess)
    XCTAssertTrue(access.installed.isEmpty)
    XCTAssertEqual(access.persistence(for: "com.google.Chrome"), .persistent)
  }

  func testValidGrantUpdatesOnlyItsRowWithoutPublishingRoutingConfiguration() throws {
    let scan = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired),
        Fixtures.installedBrowser("org.mozilla.firefox", status: .accessRequired),
      ],
      profileAccessIssues: [
        .accessRequired(bundleIdentifier: "com.google.Chrome"),
        .accessRequired(bundleIdentifier: "org.mozilla.firefox"),
      ]
    )
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let snapshot = MutableTargetSnapshot()
    snapshot.publish(Fixtures.editableConfig)
    let routing = RoutingSpy()
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.editableConfig,
      scanResult: scan,
      targeted: ["com.google.Chrome": Fixtures.discoveredChromeWithProfiles]
    )
    let access = ProfileAccessManagerSpy(installOutcome: .persistent)
    let model = makeModel(
      store: store,
      catalog: catalog,
      routing: routing,
      targetSnapshot: snapshot,
      access: access,
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()
    store.resetSaved()
    catalog.resetTargetedScanCalls()
    let publishedTargetIDs = snapshot.availableSnapshot(for: .web).targets.map(\.id)

    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )

    XCTAssertEqual(
      model.profileAccessRows.map(\.state),
      [
        .granted(profileCount: 2, persistence: .persistent),
        .accessNeeded,
      ]
    )
    XCTAssertEqual(catalog.targetedScanBundleIdentifiers, ["com.google.Chrome"])
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertEqual(model.config, Fixtures.editableConfig)
    XCTAssertEqual(
      snapshot.availableSnapshot(for: .web).targets.map(\.id),
      publishedTargetIDs
    )
    XCTAssertEqual(routing.refreshCallCount, 0)
  }

  func testSessionOnlyGrantCarriesAccuratePersistenceState() throws {
    let scan = BrowserScanResult(
      browsers: [Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired)],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
    let catalog = BrowserCatalogStub(
      scanResult: scan,
      targeted: ["com.google.Chrome": Fixtures.discoveredChrome]
    )
    let model = makeModel(
      catalog: catalog,
      access: ProfileAccessManagerSpy(installOutcome: .currentSessionOnly),
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()

    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )

    XCTAssertEqual(
      model.profileAccessRows.first?.state,
      .granted(profileCount: 1, persistence: .currentSessionOnly)
    )
    XCTAssertTrue(model.profileAccessRows.first?.hasStoredGrant == true)
  }

  func testPersistentGrantRemainsGrantedWhenManagerReopensBeforeFullScan() throws {
    let scan = BrowserScanResult(
      browsers: [Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired)],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
    let catalog = BrowserCatalogStub(
      scanResult: scan,
      targeted: ["com.google.Chrome": Fixtures.discoveredChromeWithProfiles]
    )
    let model = makeModel(
      catalog: catalog,
      access: ProfileAccessManagerSpy(installOutcome: .persistent),
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()
    model.profileAccessDidPresent()
    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )

    model.closeProfileAccess()
    model.profileAccessDidDismiss()
    model.openProfileAccessManager()

    XCTAssertEqual(
      model.profileAccessRows.first?.state,
      .granted(profileCount: 2, persistence: .persistent)
    )
    XCTAssertTrue(model.profileAccessRows.first?.hasStoredGrant == true)
    XCTAssertTrue(model.canFinishProfileAccess)
    XCTAssertEqual(model.profileAccessPresentation, .manualPending)
  }

  func testSessionOnlyGrantRemainsGrantedWhenManagerReopensBeforeFullScan() throws {
    let scan = BrowserScanResult(
      browsers: [Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired)],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
    let catalog = BrowserCatalogStub(
      scanResult: scan,
      targeted: ["com.google.Chrome": Fixtures.discoveredChrome]
    )
    let model = makeModel(
      catalog: catalog,
      access: ProfileAccessManagerSpy(installOutcome: .currentSessionOnly),
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()
    model.profileAccessDidPresent()
    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )

    model.closeProfileAccess()
    model.profileAccessDidDismiss()
    model.openProfileAccessManager()

    XCTAssertEqual(
      model.profileAccessRows.first?.state,
      .granted(profileCount: 1, persistence: .currentSessionOnly)
    )
    XCTAssertTrue(model.profileAccessRows.first?.hasStoredGrant == true)
    XCTAssertTrue(model.canFinishProfileAccess)
    XCTAssertEqual(model.profileAccessPresentation, .manualPending)
  }

  func testAuthoritativeFullScanReplacesTargetedGrantProfileCount() throws {
    let accessRequired = BrowserScanResult(
      browsers: [Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired)],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
    let loaded = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChrome.profiles
        )
      ],
      profileAccessIssues: []
    )
    let catalog = BrowserCatalogStub(
      scanResult: accessRequired,
      targeted: ["com.google.Chrome": Fixtures.discoveredChromeWithProfiles]
    )
    let model = makeModel(
      catalog: catalog,
      access: ProfileAccessManagerSpy(installOutcome: .persistent),
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()
    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )
    catalog.setScanResult(loaded)

    try model.rescan()
    model.openProfileAccessManager()

    XCTAssertEqual(
      model.profileAccessRows.first?.state,
      .granted(profileCount: 1, persistence: .persistent)
    )
    XCTAssertTrue(model.canFinishProfileAccess)
  }

  func testFinishPerformsOneAuthoritativeValidateSavePublishTransaction() throws {
    let accessRequired = BrowserScanResult(
      browsers: [Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired)],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
    let loaded = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChromeWithProfiles.profiles
        )
      ],
      profileAccessIssues: []
    )
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let snapshot = MutableTargetSnapshot()
    snapshot.publish(Fixtures.editableConfig)
    let routing = RoutingSpy()
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.editableConfig,
      scanResult: accessRequired,
      targeted: ["com.google.Chrome": Fixtures.discoveredChromeWithProfiles]
    )
    let model = makeModel(
      store: store,
      catalog: catalog,
      routing: routing,
      targetSnapshot: snapshot,
      access: ProfileAccessManagerSpy(),
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()
    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )
    model.profileAccessDidPresent()
    catalog.reconciled = Fixtures.profileEditConfig
    catalog.setScanResult(loaded)
    catalog.resetScanCalls()
    catalog.resetReconcileInputs()
    store.resetSaved()

    try model.finishProfileAccessAndRescan()

    XCTAssertEqual(catalog.scanResultCallCount, 1)
    XCTAssertEqual(catalog.reconcileInputs, [Fixtures.editableConfig])
    XCTAssertEqual(store.saved, [Fixtures.profileEditConfig])
    XCTAssertEqual(model.config, Fixtures.profileEditConfig)
    XCTAssertEqual(
      snapshot.availableSnapshot(for: .web).targets.map(\.id),
      ["work", "personal"]
    )
    XCTAssertEqual(routing.refreshCallCount, 1)
    XCTAssertEqual(
      model.profileAccessRows.first?.state,
      .granted(profileCount: 2, persistence: .persistent)
    )
    XCTAssertEqual(model.profileAccessPresentation, .idle)
  }

  func testFinishSaveFailureLeavesPublishedStateAndPresentationUnchanged() throws {
    let loaded = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChromeWithProfiles.profiles
        )
      ],
      profileAccessIssues: []
    )
    let store = ConfigStoreStub(config: Fixtures.editableConfig, saveError: TestError.denied)
    let snapshot = MutableTargetSnapshot()
    snapshot.publish(Fixtures.editableConfig)
    let routing = RoutingSpy()
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.profileEditConfig,
      scanResult: loaded
    )
    let model = makeModel(
      store: store,
      catalog: catalog,
      routing: routing,
      targetSnapshot: snapshot,
      access: ProfileAccessManagerSpy(persistence: ["com.google.Chrome": .persistent])
    )
    try model.load()
    model.openProfileAccessManager()
    model.profileAccessDidPresent()

    XCTAssertThrowsError(try model.finishProfileAccessAndRescan())

    XCTAssertEqual(model.config, Fixtures.editableConfig)
    XCTAssertEqual(
      snapshot.availableSnapshot(for: .web).targets.map(\.id),
      ["work"]
    )
    XCTAssertEqual(routing.refreshCallCount, 0)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
    XCTAssertFalse(model.errorMessage?.contains("denied") ?? false)
  }

  func testFinishSaveFailureRebuildsGrantedRowAsAuthoritativelyRevoked() throws {
    let accessRequired = BrowserScanResult(
      browsers: [Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired)],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
    let revoked = BrowserScanResult(
      browsers: [Fixtures.installedBrowser("com.google.Chrome", status: .accessRevoked)],
      profileAccessIssues: [.accessRevoked(bundleIdentifier: "com.google.Chrome")]
    )
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let snapshot = MutableTargetSnapshot()
    snapshot.publish(Fixtures.editableConfig)
    let routing = RoutingSpy()
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.editableConfig,
      scanResult: accessRequired,
      targeted: ["com.google.Chrome": Fixtures.discoveredChromeWithProfiles]
    )
    let model = makeModel(
      store: store,
      catalog: catalog,
      routing: routing,
      targetSnapshot: snapshot,
      access: ProfileAccessManagerSpy(),
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()
    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )
    model.profileAccessDidPresent()
    catalog.reconciled = Fixtures.profileEditConfig
    catalog.setScanResult(revoked)
    store.saveError = TestError.denied
    store.resetSaved()

    XCTAssertThrowsError(try model.finishProfileAccessAndRescan())

    XCTAssertEqual(model.profileAccessRows.first?.state, .accessRevoked)
    XCTAssertTrue(model.profileAccessRows.first?.hasStoredGrant == true)
    XCTAssertFalse(model.canFinishProfileAccess)
    XCTAssertEqual(model.config, Fixtures.editableConfig)
    XCTAssertEqual(snapshot.availableSnapshot(for: .web).targets.map(\.id), ["work"])
    XCTAssertEqual(routing.refreshCallCount, 0)
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertFalse(model.errorMessage?.contains("denied") ?? false)
  }

  func testFinishSaveFailureUsesAuthoritativeLoadedProfileCount() throws {
    let accessRequired = BrowserScanResult(
      browsers: [Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired)],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
    let loaded = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChrome.profiles
        )
      ],
      profileAccessIssues: []
    )
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let snapshot = MutableTargetSnapshot()
    snapshot.publish(Fixtures.editableConfig)
    let routing = RoutingSpy()
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.editableConfig,
      scanResult: accessRequired,
      targeted: ["com.google.Chrome": Fixtures.discoveredChromeWithProfiles]
    )
    let model = makeModel(
      store: store,
      catalog: catalog,
      routing: routing,
      targetSnapshot: snapshot,
      access: ProfileAccessManagerSpy(),
      profileRootValidator: profileRootValidator(validRoots: ["/Chrome"])
    )
    try model.load()
    try model.grantProfileAccess(
      for: "com.google.Chrome",
      root: URL(fileURLWithPath: "/Chrome")
    )
    model.profileAccessDidPresent()
    catalog.reconciled = Fixtures.profileEditConfig
    catalog.setScanResult(loaded)
    store.saveError = TestError.denied
    store.resetSaved()

    XCTAssertThrowsError(try model.finishProfileAccessAndRescan())

    XCTAssertEqual(
      model.profileAccessRows.first?.state,
      .granted(profileCount: 1, persistence: .persistent)
    )
    XCTAssertTrue(model.profileAccessRows.first?.hasStoredGrant == true)
    XCTAssertTrue(model.canFinishProfileAccess)
    XCTAssertEqual(model.config, Fixtures.editableConfig)
    XCTAssertEqual(snapshot.availableSnapshot(for: .web).targets.map(\.id), ["work"])
    XCTAssertEqual(routing.refreshCallCount, 0)
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertFalse(model.errorMessage?.contains("denied") ?? false)
  }

  func testRemovalCommitsFallbackAndPreservesOtherGrantedRows() throws {
    let initial = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChromeWithProfiles.profiles
        ),
        Fixtures.installedBrowser(
          "org.mozilla.firefox",
          status: .loaded,
          profiles: [
            DiscoveredProfile(identifier: "default", displayName: "Default", directoryURL: nil)
          ]
        ),
      ],
      profileAccessIssues: []
    )
    let afterRemoval = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired),
        Fixtures.installedBrowser(
          "org.mozilla.firefox",
          status: .loaded,
          profiles: [
            DiscoveredProfile(identifier: "default", displayName: "Default", directoryURL: nil)
          ]
        ),
      ],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let routing = RoutingSpy()
    let access = ProfileAccessManagerSpy(
      persistence: [
        "com.google.Chrome": .persistent,
        "org.mozilla.firefox": .persistent,
      ]
    )
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.editableConfig,
      scanResult: initial
    )
    let model = makeModel(
      store: store,
      catalog: catalog,
      routing: routing,
      access: access
    )
    try model.load()
    model.openProfileAccessManager()
    model.profileAccessDidPresent()
    catalog.setScanResult(afterRemoval)
    catalog.resetScanCalls()
    store.resetSaved()

    try model.removeProfileAccess(for: "com.google.Chrome")

    XCTAssertEqual(access.removedBundleIdentifiers, ["com.google.Chrome"])
    XCTAssertEqual(catalog.scanResultCallCount, 1)
    XCTAssertEqual(store.saved, [Fixtures.editableConfig])
    XCTAssertEqual(routing.refreshCallCount, 1)
    XCTAssertEqual(
      model.profileAccessRows.map(\.state),
      [
        .accessNeeded,
        .granted(profileCount: 1, persistence: .persistent),
      ]
    )
    XCTAssertEqual(model.profileAccessPresentation, .presented)
  }

  func testRemovalWithNonAuthoritativeScanRebuildsRowsFromActualGrantState() throws {
    let initial = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChromeWithProfiles.profiles
        ),
        Fixtures.installedBrowser(
          "org.mozilla.firefox",
          status: .loaded,
          profiles: [
            DiscoveredProfile(identifier: "default", displayName: "Default", directoryURL: nil)
          ]
        ),
      ],
      profileAccessIssues: []
    )
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let snapshot = MutableTargetSnapshot()
    snapshot.publish(Fixtures.editableConfig)
    let routing = RoutingSpy()
    let access = ProfileAccessManagerSpy(
      persistence: [
        "com.google.Chrome": .persistent,
        "org.mozilla.firefox": .persistent,
      ]
    )
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.editableConfig,
      scanResult: initial
    )
    let model = makeModel(
      store: store,
      catalog: catalog,
      routing: routing,
      targetSnapshot: snapshot,
      access: access
    )
    try model.load()
    model.openProfileAccessManager()
    model.profileAccessDidPresent()
    catalog.setScanResult(
      BrowserScanResult(browsers: [], profileAccessIssues: [], isAuthoritative: false)
    )
    store.resetSaved()

    XCTAssertThrowsError(try model.removeProfileAccess(for: "com.google.Chrome"))

    XCTAssertNil(access.persistence(for: "com.google.Chrome"))
    XCTAssertEqual(
      model.profileAccessRows.map(\.state),
      [
        .accessNeeded,
        .granted(profileCount: 1, persistence: .persistent),
      ]
    )
    XCTAssertEqual(model.profileAccessRows.map(\.hasStoredGrant), [false, true])
    XCTAssertTrue(model.canFinishProfileAccess)
    XCTAssertEqual(model.config, Fixtures.editableConfig)
    XCTAssertEqual(snapshot.availableSnapshot(for: .web).targets.map(\.id), ["work"])
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertEqual(routing.refreshCallCount, 0)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
  }

  func testRemovalSaveFailureRebuildsRowsWithoutPublishingStaleFallback() throws {
    let initial = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChromeWithProfiles.profiles
        ),
        Fixtures.installedBrowser(
          "org.mozilla.firefox",
          status: .loaded,
          profiles: [
            DiscoveredProfile(identifier: "default", displayName: "Default", directoryURL: nil)
          ]
        ),
      ],
      profileAccessIssues: []
    )
    let afterRemoval = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired),
        Fixtures.installedBrowser(
          "org.mozilla.firefox",
          status: .loaded,
          profiles: [
            DiscoveredProfile(identifier: "default", displayName: "Default", directoryURL: nil)
          ]
        ),
      ],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let snapshot = MutableTargetSnapshot()
    snapshot.publish(Fixtures.editableConfig)
    let routing = RoutingSpy()
    let access = ProfileAccessManagerSpy(
      persistence: [
        "com.google.Chrome": .persistent,
        "org.mozilla.firefox": .persistent,
      ]
    )
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.editableConfig,
      scanResult: initial
    )
    let model = makeModel(
      store: store,
      catalog: catalog,
      routing: routing,
      targetSnapshot: snapshot,
      access: access
    )
    try model.load()
    model.openProfileAccessManager()
    model.profileAccessDidPresent()
    catalog.reconciled = Fixtures.profileEditConfig
    catalog.setScanResult(afterRemoval)
    store.saveError = TestError.denied
    store.resetSaved()

    XCTAssertThrowsError(try model.removeProfileAccess(for: "com.google.Chrome"))

    XCTAssertNil(access.persistence(for: "com.google.Chrome"))
    XCTAssertEqual(
      model.profileAccessRows.map(\.state),
      [
        .accessNeeded,
        .granted(profileCount: 1, persistence: .persistent),
      ]
    )
    XCTAssertEqual(model.profileAccessRows.map(\.hasStoredGrant), [false, true])
    XCTAssertTrue(model.canFinishProfileAccess)
    XCTAssertEqual(model.config, Fixtures.editableConfig)
    XCTAssertEqual(snapshot.availableSnapshot(for: .web).targets.map(\.id), ["work"])
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertEqual(routing.refreshCallCount, 0)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
    XCTAssertFalse(model.errorMessage?.contains("denied") ?? false)
  }

  func testNonAuthoritativeUserRescanRetainsManualManagerInventory() throws {
    let initial = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChromeWithProfiles.profiles
        )
      ],
      profileAccessIssues: []
    )
    let access = ProfileAccessManagerSpy(
      persistence: ["com.google.Chrome": .persistent]
    )
    let catalog = BrowserCatalogStub(scanResult: initial)
    let model = makeModel(catalog: catalog, access: access)
    try model.load()
    catalog.setScanResult(
      BrowserScanResult(browsers: [], profileAccessIssues: [], isAuthoritative: false)
    )

    try model.userRequestedRescan()
    model.openProfileAccessManager()

    XCTAssertEqual(model.profileAccessRows.map(\.bundleIdentifier), ["com.google.Chrome"])
    XCTAssertEqual(
      model.profileAccessRows.first?.state,
      .granted(profileCount: 2, persistence: .persistent)
    )
    XCTAssertEqual(model.profileAccessPresentation, .manualPending)
  }

  func testThirdOnboardingStepIsDisabledWithoutValidEnabledTarget() throws {
    let unavailable = Fixtures.target(
      isEnabled: true,
      availability: .unavailable
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: Fixtures.config.browsers,
      targets: [unavailable]
    )
    let model = makeModel(store: ConfigStoreStub(config: config))

    try model.load()

    XCTAssertFalse(model.canRequestDefaultBrowser)
  }

  func testAutomaticProfileAccessAllowsReviewAdvanceButBlocksDefaultRequestWhileQueued()
    async throws
  {
    let defaults = DefaultBrowserSpy()
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      catalog: BrowserCatalogStub(
        reconciled: Fixtures.config,
        scanResult: automaticProfileAccessScan
      ),
      preferences: PreferencesStub(integers: ["onboardingStep": 2]),
      defaultBrowser: defaults
    )
    try model.load()

    XCTAssertTrue(model.canContinueOnboardingReview)
    XCTAssertTrue(model.hasUnresolvedAutomaticProfileAccess)
    XCTAssertFalse(model.canRequestDefaultBrowser)

    model.advanceOnboarding()
    await model.requestDefaultBrowser()

    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertTrue(defaults.requestedSchemes.isEmpty)
  }

  func testPresentedAutomaticProfileAccessBlocksDefaultRequestUntilSkipped() async throws {
    let defaults = DefaultBrowserSpy()
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      catalog: BrowserCatalogStub(
        reconciled: Fixtures.config,
        scanResult: automaticProfileAccessScan
      ),
      preferences: PreferencesStub(integers: ["onboardingStep": 3]),
      defaultBrowser: defaults
    )
    try model.load()
    model.profileAccessDidPresent()

    XCTAssertTrue(model.hasUnresolvedAutomaticProfileAccess)
    XCTAssertFalse(model.canRequestDefaultBrowser)
    await model.requestDefaultBrowser()
    XCTAssertTrue(defaults.requestedSchemes.isEmpty)

    model.skipProfileAccess()
    model.profileAccessDidDismiss()

    XCTAssertFalse(model.hasUnresolvedAutomaticProfileAccess)
    XCTAssertTrue(model.canRequestDefaultBrowser)
    await model.requestDefaultBrowser()
    XCTAssertEqual(defaults.requestedSchemes, ["http", "https"])
  }

  func testSkipDoesNotEnableDefaultConsentUntilPhysicalSurfaceDismissal() async throws {
    let defaults = DefaultBrowserSpy()
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      catalog: BrowserCatalogStub(
        reconciled: Fixtures.config,
        scanResult: automaticProfileAccessScan
      ),
      preferences: PreferencesStub(integers: ["onboardingStep": 3]),
      defaultBrowser: defaults
    )
    try model.load()
    model.profileAccessDidPresent()

    model.skipProfileAccess()
    await model.requestDefaultBrowser()

    XCTAssertTrue(model.isProfileAccessSurfaceActive)
    XCTAssertFalse(model.canRequestDefaultBrowser)
    XCTAssertTrue(defaults.requestedSchemes.isEmpty)

    model.profileAccessDidDismiss()
    await model.requestDefaultBrowser()

    XCTAssertTrue(model.canRequestDefaultBrowser)
    XCTAssertEqual(defaults.requestedSchemes, ["http", "https"])
  }

  func testOpeningManagerCannotDowngradePresentedAutomaticProfileAccess() throws {
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      catalog: BrowserCatalogStub(
        reconciled: Fixtures.config,
        scanResult: automaticProfileAccessScan
      ),
      preferences: PreferencesStub(integers: ["onboardingStep": 3])
    )
    try model.load()
    model.profileAccessDidPresent()
    let rowsBeforeReentrantOpen = model.profileAccessRows

    model.openProfileAccessManager()

    XCTAssertEqual(model.profileAccessPresentation, .presented)
    XCTAssertEqual(model.profileAccessRows, rowsBeforeReentrantOpen)
    XCTAssertTrue(model.hasUnresolvedAutomaticProfileAccess)
    XCTAssertFalse(model.canRequestDefaultBrowser)
  }

  func testOpeningManagerCannotDowngradeQueuedAutomaticProfileAccessOrReachDefaultService()
    async throws
  {
    let defaults = DefaultBrowserSpy()
    let scan = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired),
        Fixtures.installedBrowser("org.mozilla.firefox", status: .loaded),
      ],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      catalog: BrowserCatalogStub(
        reconciled: Fixtures.config,
        scanResult: scan
      ),
      preferences: PreferencesStub(integers: ["onboardingStep": 3]),
      defaultBrowser: defaults
    )
    try model.load()
    let automaticRows = model.profileAccessRows

    model.openProfileAccessManager()
    await model.requestDefaultBrowser()

    XCTAssertEqual(model.profileAccessPresentation, .automaticPending)
    XCTAssertEqual(model.profileAccessRows, automaticRows)
    XCTAssertEqual(model.profileAccessRows.map(\.bundleIdentifier), ["com.google.Chrome"])
    XCTAssertTrue(model.hasUnresolvedAutomaticProfileAccess)
    XCTAssertFalse(model.canRequestDefaultBrowser)
    XCTAssertTrue(defaults.requestedSchemes.isEmpty)
  }

  func testChooserPreviewIsBlockedOnlyWhileProfileAccessPanelIsPresented() throws {
    let routing = RoutingSpy()
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      catalog: BrowserCatalogStub(
        reconciled: Fixtures.config,
        scanResult: automaticProfileAccessScan
      ),
      routing: routing
    )
    try model.load()
    model.profileAccessDidPresent()

    model.previewChooser(kind: .web)
    XCTAssertTrue(routing.previewedURLs.isEmpty)

    model.closeProfileAccess()
    model.profileAccessDidDismiss()
    model.previewChooser(kind: .web)
    XCTAssertEqual(routing.previewedURLs.count, 1)
  }

  func testUserRescanCannotRewriteStateWhileProfileAccessSurfaceIsPhysicallyActive() throws {
    let catalog = BrowserCatalogStub(
      reconciled: Fixtures.config,
      scanResult: automaticProfileAccessScan
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      catalog: catalog,
      preferences: PreferencesStub(integers: ["onboardingStep": 3])
    )
    try model.load()
    model.profileAccessDidPresent()
    let rowsBeforeRescan = model.profileAccessRows
    catalog.resetScanCalls()

    try model.userRequestedRescan()

    XCTAssertEqual(catalog.scanResultCallCount, 0)
    XCTAssertEqual(model.profileAccessRows, rowsBeforeRescan)
    XCTAssertEqual(model.profileAccessPresentation, .presented)
    XCTAssertTrue(model.isProfileAccessSurfaceActive)
    XCTAssertTrue(model.hasUnresolvedAutomaticProfileAccess)
    XCTAssertFalse(model.canRequestDefaultBrowser)
  }

  func testManualProfileAccessManagerDoesNotLeaveAutomaticBlockerAfterDismissal() async throws {
    let defaults = DefaultBrowserSpy()
    let scan = BrowserScanResult(
      browsers: [
        Fixtures.installedBrowser(
          "com.google.Chrome",
          status: .loaded,
          profiles: Fixtures.discoveredChrome.profiles
        )
      ],
      profileAccessIssues: []
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      catalog: BrowserCatalogStub(reconciled: Fixtures.config, scanResult: scan),
      preferences: PreferencesStub(integers: ["onboardingStep": 3]),
      defaultBrowser: defaults
    )
    try model.load()
    model.openProfileAccessManager()
    model.profileAccessDidPresent()

    XCTAssertFalse(model.hasUnresolvedAutomaticProfileAccess)
    XCTAssertFalse(model.canRequestDefaultBrowser)
    await model.requestDefaultBrowser()
    XCTAssertTrue(defaults.requestedSchemes.isEmpty)

    model.profileAccessDidDismiss()
    XCTAssertTrue(model.canRequestDefaultBrowser)
    await model.requestDefaultBrowser()

    XCTAssertEqual(defaults.requestedSchemes, ["http", "https"])
  }

  func testDefaultRequestCoversHTTPAndHTTPSOnlyWhenTargetExists() async throws {
    let defaults = DefaultBrowserSpy(status: .init(http: .notDefault, https: .notDefault))
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultBrowser()

    XCTAssertEqual(defaults.requestedSchemes, ["http", "https"])
  }

  func testConfirmedBrowserDefaultAdvancesNewUserToMailReview() async throws {
    let incomplete = DefaultHandlerStatus(
      http: .notDefault,
      https: .notDefault,
      mailto: .notDefault
    )
    let confirmed = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let defaults = DefaultBrowserSpy(
      statuses: [incomplete, confirmed]
    )
    let preferences = PreferencesStub(integers: [
      "onboardingVersion": 2,
      "onboardingStep": 3,
    ])
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      preferences: preferences,
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultBrowser()

    XCTAssertEqual(defaults.requestedSchemes, ["http", "https"])
    XCTAssertEqual(model.onboardingStep, 4)
    XCTAssertFalse(model.isOnboardingComplete)
  }

  func testDefaultRequestDoesNothingWithoutValidEnabledTarget() async throws {
    let defaults = DefaultBrowserSpy()
    let model = makeModel(
      store: ConfigStoreStub(config: .initial),
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultBrowser()

    XCTAssertTrue(defaults.requestedSchemes.isEmpty)
  }

  func testDeclinedDefaultConsentPublishesRecoveryAndRefreshesStatus() async throws {
    let defaults = DefaultBrowserSpy(
      status: .init(http: .notDefault, https: .notDefault),
      requestError: TestError.declined
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultBrowser()

    XCTAssertEqual(model.defaultStatus, .init(http: .notDefault, https: .notDefault))
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(defaults.statusCallCount, 2)
    defaults.requestError = nil
    await model.requestDefaultBrowser()
    XCTAssertNotNil(model.errorMessage)
  }

  func testNonthrowingDefaultRequestThatRemainsNotDefaultDoesNotCompleteOnboarding() async throws {
    let incomplete = DefaultHandlerStatus(http: .notDefault, https: .notDefault)
    let preferences = PreferencesStub(integers: ["onboardingStep": 3])
    let defaults = DefaultBrowserSpy(statuses: [incomplete, incomplete])
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      preferences: preferences,
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultBrowser()

    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertFalse(model.isOnboardingComplete)
    XCTAssertNotNil(model.errorMessage)
  }

  func testPartialDefaultStatusDoesNotCompleteOnboarding() async throws {
    let incomplete = DefaultHandlerStatus(http: .notDefault, https: .notDefault)
    let partial = DefaultHandlerStatus(http: .isDefault, https: .notDefault)
    let preferences = PreferencesStub(integers: ["onboardingStep": 3])
    let defaults = DefaultBrowserSpy(statuses: [incomplete, partial])
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      preferences: preferences,
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultBrowser()

    XCTAssertEqual(model.defaultStatus, partial)
    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertFalse(model.isOnboardingComplete)
    XCTAssertNotNil(model.errorMessage)
  }

  func testDualSchemeDefaultStatusAdvancesToMailReview() async throws {
    let incomplete = DefaultHandlerStatus(http: .notDefault, https: .notDefault)
    let complete = DefaultHandlerStatus(http: .isDefault, https: .isDefault)
    let preferences = PreferencesStub(integers: [
      "onboardingVersion": 2,
      "onboardingStep": 3,
    ])
    let defaults = DefaultBrowserSpy(statuses: [incomplete, complete])
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      preferences: preferences,
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultBrowser()

    XCTAssertEqual(model.defaultStatus, complete)
    XCTAssertEqual(model.onboardingStep, 4)
    XCTAssertFalse(model.isOnboardingComplete)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(preferences.setIntegers["onboardingStep"], 4)
  }

  func testLegacyCompletedUserMigratesDirectlyToNewCompletedStep() throws {
    let preferences = PreferencesStub(integers: ["onboardingStep": 4])
    let defaults = DefaultBrowserSpy(
      status: .init(http: .isDefault, https: .isDefault, mailto: .notDefault)
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      preferences: preferences,
      defaultBrowser: defaults
    )

    try model.load()

    XCTAssertEqual(model.onboardingStep, 6)
    XCTAssertTrue(model.isOnboardingComplete)
    XCTAssertEqual(preferences.setIntegers["onboardingVersion"], 2)
    XCTAssertEqual(preferences.setIntegers["onboardingStep"], 6)
  }

  func testLegacyCompletionWithoutConfirmedBrowserReturnsToDefaultBrowserStep() throws {
    let preferences = PreferencesStub(integers: ["onboardingStep": 4])
    let defaults = DefaultBrowserSpy(
      status: .init(http: .isDefault, https: .notDefault)
    )
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.config),
      preferences: preferences,
      defaultBrowser: defaults
    )

    try model.load()

    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertFalse(model.isOnboardingComplete)
    XCTAssertEqual(preferences.setIntegers["onboardingStep"], 3)
  }

  func testIncompleteLegacyStepsArePreservedDuringVersionMigration() throws {
    for step in 1...3 {
      let preferences = PreferencesStub(integers: ["onboardingStep": step])
      let model = makeModel(preferences: preferences)

      try model.load()

      XCTAssertEqual(model.onboardingStep, step)
      XCTAssertEqual(preferences.setIntegers["onboardingVersion"], 2)
      XCTAssertEqual(preferences.setIntegers["onboardingStep"], step)
    }
  }

  func testVersionTwoMailReviewWithoutConfirmedBrowserReturnsToDefaultBrowserStep() throws {
    let preferences = PreferencesStub(integers: [
      "onboardingVersion": 2,
      "onboardingStep": 4,
    ])
    let defaults = DefaultBrowserSpy(
      status: .init(http: .isDefault, https: .notDefault, mailto: .notDefault)
    )
    let model = makeModel(
      preferences: preferences,
      defaultBrowser: defaults
    )

    try model.load()

    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertFalse(model.isOnboardingComplete)
    XCTAssertEqual(preferences.setIntegers["onboardingStep"], 3)

    model.skipMailSetup()

    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertFalse(model.isOnboardingComplete)
    XCTAssertTrue(defaults.requestedSchemes.isEmpty)
  }

  func testVersionTwoDefaultMailWithoutConfirmedBrowserReturnsToDefaultBrowserStep()
    async throws
  {
    let unconfirmed = DefaultHandlerStatus(
      http: .notDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let mailConfirmed = DefaultHandlerStatus(
      http: .notDefault,
      https: .isDefault,
      mailto: .isDefault
    )
    let preferences = PreferencesStub(integers: [
      "onboardingVersion": 2,
      "onboardingStep": 5,
    ])
    let defaults = DefaultBrowserSpy(statuses: [unconfirmed, mailConfirmed])
    let model = makeModel(
      preferences: preferences,
      defaultBrowser: defaults
    )

    try model.load()

    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertFalse(model.isOnboardingComplete)
    XCTAssertEqual(preferences.setIntegers["onboardingStep"], 3)

    await model.requestDefaultMail()

    XCTAssertEqual(defaults.requestedSchemes, ["mailto"])
    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertFalse(model.isOnboardingComplete)
  }

  func testRefreshLosingBrowserDefaultFromMailReviewPreventsSkipCompletingOnboarding()
    throws
  {
    let confirmed = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let browserUnconfirmed = DefaultHandlerStatus(
      http: .isDefault,
      https: .notDefault,
      mailto: .notDefault
    )
    let defaults = DefaultBrowserSpy(statuses: [confirmed, browserUnconfirmed])
    let model = makeModel(
      preferences: PreferencesStub(integers: [
        "onboardingVersion": 2,
        "onboardingStep": 4,
      ]),
      defaultBrowser: defaults
    )
    try model.load()
    XCTAssertEqual(model.onboardingStep, 4)

    model.refreshDefaultStatus()
    model.skipMailSetup()

    XCTAssertEqual(model.defaultStatus, browserUnconfirmed)
    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertFalse(model.isOnboardingComplete)
    XCTAssertTrue(defaults.requestedSchemes.isEmpty)
  }

  func testRefreshLosingBrowserDefaultFromDefaultMailPreventsMailConfirmationCompletingOnboarding()
    async throws
  {
    let confirmed = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let browserUnconfirmed = DefaultHandlerStatus(
      http: .notDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let mailConfirmedWithoutBrowser = DefaultHandlerStatus(
      http: .notDefault,
      https: .isDefault,
      mailto: .isDefault
    )
    let defaults = DefaultBrowserSpy(
      statuses: [confirmed, browserUnconfirmed, mailConfirmedWithoutBrowser]
    )
    let model = makeModel(
      preferences: PreferencesStub(integers: [
        "onboardingVersion": 2,
        "onboardingStep": 5,
      ]),
      defaultBrowser: defaults
    )
    try model.load()
    XCTAssertEqual(model.onboardingStep, 5)

    model.refreshDefaultStatus()
    await model.requestDefaultMail()

    XCTAssertEqual(model.defaultStatus, mailConfirmedWithoutBrowser)
    XCTAssertEqual(defaults.requestedSchemes, ["mailto"])
    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertFalse(model.isOnboardingComplete)
  }

  func testContinueMailReviewRequiresEnabledAvailableMailTarget() throws {
    let preferences = PreferencesStub(integers: [
      "onboardingVersion": 2,
      "onboardingStep": 4,
    ])
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.webAndMailConfig),
      catalog: BrowserCatalogStub(reconciled: Fixtures.webAndMailConfig),
      mailCatalog: .authoritative([Fixtures.appleMailDiscovery]),
      preferences: preferences,
      defaultBrowser: DefaultBrowserSpy(
        status: .init(http: .isDefault, https: .isDefault)
      )
    )
    try model.load()

    model.continueMailReview()

    XCTAssertEqual(model.onboardingStep, 5)
  }

  func testContinueMailReviewDoesNothingWithoutEnabledAvailableMailTarget() throws {
    let disabledTarget = RouteTarget(
      id: Fixtures.appleMailTarget.id,
      applicationID: Fixtures.appleMailTarget.applicationID,
      label: Fixtures.appleMailTarget.label,
      isEnabled: false,
      sortOrder: Fixtures.appleMailTarget.sortOrder,
      origin: Fixtures.appleMailTarget.origin,
      availability: .available,
      capability: .mail
    )
    let unavailableTarget = RouteTarget(
      id: Fixtures.appleMailTarget.id,
      applicationID: Fixtures.appleMailTarget.applicationID,
      label: Fixtures.appleMailTarget.label,
      isEnabled: true,
      sortOrder: Fixtures.appleMailTarget.sortOrder,
      origin: Fixtures.appleMailTarget.origin,
      availability: .unavailable,
      capability: .mail
    )
    let invalidConfigs = [
      Fixtures.config,
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        applications: Fixtures.webAndMailConfig.applications,
        targets: Fixtures.config.targets + [disabledTarget]
      ),
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        applications: Fixtures.webAndMailConfig.applications,
        targets: Fixtures.config.targets + [unavailableTarget]
      ),
    ]

    for config in invalidConfigs {
      let model = makeModel(
        store: ConfigStoreStub(config: config),
        catalog: BrowserCatalogStub(reconciled: config),
        mailCatalog: MailCatalogStub(
          scan: .init(applications: [], isAuthoritative: false),
          runtimeFallback: config
        ),
        preferences: PreferencesStub(integers: [
          "onboardingVersion": 2,
          "onboardingStep": 4,
        ]),
        defaultBrowser: DefaultBrowserSpy(
          status: .init(http: .isDefault, https: .isDefault)
        )
      )
      try model.load()

      model.continueMailReview()

      XCTAssertEqual(model.onboardingStep, 4)
    }
  }

  func testSkipMailSetupFromReviewCompletesWithoutDefaultRequest() throws {
    let defaults = DefaultBrowserSpy(
      status: .init(http: .isDefault, https: .isDefault, mailto: .notDefault)
    )
    let model = makeModel(
      preferences: PreferencesStub(integers: [
        "onboardingVersion": 2,
        "onboardingStep": 4,
      ]),
      defaultBrowser: defaults
    )
    try model.load()

    model.skipMailSetup()

    XCTAssertEqual(model.onboardingStep, 6)
    XCTAssertTrue(model.isOnboardingComplete)
    XCTAssertTrue(defaults.requestedSchemes.isEmpty)
  }

  func testSkipMailSetupFromDefaultStepClearsMailErrorAndCompletes() async throws {
    let status = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let defaults = DefaultBrowserSpy(
      statuses: [status, status],
      requestError: TestError.declined
    )
    let model = makeModel(
      preferences: PreferencesStub(integers: [
        "onboardingVersion": 2,
        "onboardingStep": 5,
      ]),
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultMail()
    XCTAssertNotNil(model.mailErrorMessage)

    model.skipMailSetup()

    XCTAssertEqual(model.onboardingStep, 6)
    XCTAssertTrue(model.isOnboardingComplete)
    XCTAssertNil(model.mailErrorMessage)
    XCTAssertEqual(defaults.requestedSchemes, ["mailto"])
  }

  func testMailDefaultRequestOutsideOnboardingRefreshesWithoutChangingCompletion() async throws {
    let before = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let refreshed = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .isDefault
    )
    let defaults = DefaultBrowserSpy(statuses: [before, refreshed])
    let model = makeModel(
      preferences: PreferencesStub(integers: [
        "onboardingVersion": 2,
        "onboardingStep": 6,
      ]),
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultMail()

    XCTAssertEqual(defaults.requestedSchemes, ["mailto"])
    XCTAssertEqual(model.defaultStatus, refreshed)
    XCTAssertEqual(model.onboardingStep, 6)
    XCTAssertTrue(model.isOnboardingComplete)
  }

  func testSkipMailSetupOutsideMailStepsDoesNothing() throws {
    let defaults = DefaultBrowserSpy(
      status: .init(http: .isDefault, https: .isDefault, mailto: .notDefault)
    )
    let model = makeModel(
      preferences: PreferencesStub(integers: [
        "onboardingVersion": 2,
        "onboardingStep": 3,
      ]),
      defaultBrowser: defaults
    )
    try model.load()

    model.skipMailSetup()

    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertTrue(defaults.requestedSchemes.isEmpty)
  }

  func testConfirmedMailDefaultCompletesOnboarding() async throws {
    let before = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let confirmed = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .isDefault
    )
    let defaults = DefaultBrowserSpy(statuses: [before, confirmed])
    let model = makeModel(
      preferences: PreferencesStub(integers: [
        "onboardingVersion": 2,
        "onboardingStep": 5,
      ]),
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultMail()

    XCTAssertEqual(defaults.requestedSchemes, ["mailto"])
    XCTAssertEqual(model.onboardingStep, 6)
    XCTAssertTrue(model.isOnboardingComplete)
    XCTAssertNil(model.mailErrorMessage)
  }

  func testDeclinedMailDefaultRequestRefreshesAndRemainsAtDefaultMailStep() async throws {
    let status = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let defaults = DefaultBrowserSpy(
      statuses: [status, status],
      requestError: TestError.declined
    )
    let model = makeModel(
      preferences: PreferencesStub(integers: [
        "onboardingVersion": 2,
        "onboardingStep": 5,
      ]),
      defaultBrowser: defaults
    )
    try model.load()

    await model.requestDefaultMail()

    XCTAssertEqual(defaults.requestedSchemes, ["mailto"])
    XCTAssertEqual(defaults.statusCallCount, 2)
    XCTAssertEqual(model.onboardingStep, 5)
    XCTAssertFalse(model.isOnboardingComplete)
    XCTAssertNotNil(model.mailErrorMessage)
  }

  func testUnknownMailConfirmationRemainsAtDefaultMailStep() async throws {
    let before = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let unknown = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .unknown
    )
    let model = makeModel(
      preferences: PreferencesStub(integers: [
        "onboardingVersion": 2,
        "onboardingStep": 5,
      ]),
      defaultBrowser: DefaultBrowserSpy(statuses: [before, unknown])
    )
    try model.load()

    await model.requestDefaultMail()

    XCTAssertEqual(model.defaultStatus.mailto, .unknown)
    XCTAssertEqual(model.onboardingStep, 5)
    XCTAssertFalse(model.isOnboardingComplete)
    XCTAssertNotNil(model.mailErrorMessage)
  }

  func testCompletedVersionTwoUserRemainsCompleteAfterMailDefaultChanges() throws {
    let initial = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .isDefault
    )
    let changed = DefaultHandlerStatus(
      http: .isDefault,
      https: .isDefault,
      mailto: .notDefault
    )
    let model = makeModel(
      preferences: PreferencesStub(integers: [
        "onboardingVersion": 2,
        "onboardingStep": 6,
      ]),
      defaultBrowser: DefaultBrowserSpy(statuses: [initial, changed])
    )
    try model.load()

    model.refreshDefaultStatus()

    XCTAssertEqual(model.defaultStatus.mailto, .notDefault)
    XCTAssertEqual(model.onboardingStep, 6)
    XCTAssertTrue(model.isOnboardingComplete)
  }

  func testAdvanceOnboardingAllowsOrdinaryEarlierStepProgression() throws {
    let preferences = PreferencesStub(integers: ["onboardingStep": 1])
    let model = makeModel(preferences: preferences)
    try model.load()

    model.advanceOnboarding()

    XCTAssertEqual(model.onboardingStep, 2)
    XCTAssertEqual(preferences.setIntegers["onboardingStep"], 2)
  }

  func testLoginToggleRollsBackWhenServiceThrows() throws {
    let login = LoginItemStub(isEnabled: false, setError: TestError.denied)
    let model = makeModel(loginItem: login)
    try model.load()

    model.setLaunchAtLogin(true)

    XCTAssertFalse(model.launchesAtLogin)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(login.requestedValues, [true])
  }

  func testURLVisibilityChangePersistsImmediately() throws {
    let preferences = PreferencesStub()
    let model = makeModel(preferences: preferences)
    try model.load()

    model.showsURLInChooser = false

    XCTAssertEqual(preferences.setBooleans["showsURLInChooser"], false)
  }

  func testAcceptValidatesBeforeRouting() throws {
    let routing = RoutingSpy()
    let model = makeModel(routing: routing)
    try model.load()

    model.accept(url: URL(string: "file:///tmp/private")!)
    XCTAssertTrue(routing.acceptedURLs.isEmpty)
    XCTAssertEqual(
      model.errorMessage,
      "Only valid HTTP, HTTPS, and mailto URLs can be opened."
    )

    model.accept(url: URL(string: "https://example.com/path")!)
    model.accept(url: URL(string: "mailto:person@example.com?subject=Private")!)

    XCTAssertEqual(
      routing.acceptedURLs,
      [
        URL(string: "https://example.com/path")!,
        URL(string: "mailto:person@example.com?subject=Private")!,
      ]
    )
    XCTAssertNil(model.errorMessage)
  }

  func testMultiCharacterLabelPersistenceDoesNotRefreshChooserUntilSettingsClose() throws {
    let routing = RoutingSpy()
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.editableConfig),
      routing: routing
    )
    try model.load()

    try model.renameTarget(id: "work", label: "C")
    try model.renameTarget(id: "work", label: "Cl")
    try model.renameTarget(id: "work", label: "Client")

    XCTAssertEqual(routing.refreshCallCount, 0)

    model.settingsDidClose()

    XCTAssertEqual(routing.refreshCallCount, 1)
  }

  func testChooserPreviewNeverUsesAcceptedURLPath() throws {
    let routing = RoutingSpy()
    let model = makeModel(routing: routing)
    try model.load()

    model.previewChooser(kind: .web)

    XCTAssertEqual(routing.previewedURLs.count, 1)
    XCTAssertTrue(routing.acceptedURLs.isEmpty)
  }

  func testDuplicateLabelsAreAllowedAndPersisted() throws {
    let config = Fixtures.editableConfig
    let store = ConfigStoreStub(config: config)
    let model = makeModel(store: store)
    try model.load()

    try model.renameTarget(id: "work-private", label: "Work")

    XCTAssertEqual(model.targets.map(\.label), ["Work", "Work"])
    XCTAssertEqual(store.saved.last, model.config)
  }

  func testTargetEditPersistsWithoutRefreshingChooserBeforeSettingsClose() throws {
    let routing = RoutingSpy()
    let model = makeModel(
      store: ConfigStoreStub(config: Fixtures.editableConfig),
      routing: routing
    )
    try model.load()

    try model.renameTarget(id: "work", label: "Client Work")

    XCTAssertEqual(routing.refreshCallCount, 0)
  }

  func testMailTargetCanBeRenamedAndEnabledWithoutLosingCapability() throws {
    let store = ConfigStoreStub(config: Fixtures.webAndMailConfig)
    let snapshot = MutableTargetSnapshot()
    let model = makeModel(
      store: store,
      mailCatalog: .nonAuthoritative,
      targetSnapshot: snapshot
    )
    try model.load()

    try model.setMailTargetEnabled(id: Fixtures.appleMailTarget.id, isEnabled: false)
    XCTAssertTrue(snapshot.availableSnapshot(for: .mail).targets.isEmpty)
    try model.setMailTargetEnabled(id: Fixtures.appleMailTarget.id, isEnabled: true)
    try model.renameTarget(id: Fixtures.appleMailTarget.id, label: "Personal Mail")

    let edited = try XCTUnwrap(
      model.mailTargets.first { $0.id == Fixtures.appleMailTarget.id }
    )
    XCTAssertTrue(edited.isEnabled)
    XCTAssertEqual(edited.label, "Personal Mail")
    XCTAssertEqual(edited.capability, .mail)
    XCTAssertEqual(
      snapshot.availableSnapshot(for: .mail).targets.first {
        $0.id == Fixtures.appleMailTarget.id
      },
      edited
    )
    XCTAssertNil(model.mailErrorMessage)
    XCTAssertEqual(store.saved.last, model.config)
  }

  func testMailEditingRejectsWebTargetsAndBrowserEditingRejectsMailTargets() throws {
    let store = ConfigStoreStub(config: Fixtures.webAndMailConfig)
    let model = makeModel(store: store, mailCatalog: .nonAuthoritative)
    try model.load()
    let before = model.config

    XCTAssertThrowsError(
      try model.setMailTargetEnabled(id: Fixtures.browserConfig.targets[0].id, isEnabled: false)
    )
    XCTAssertThrowsError(
      try model.setTargetMode(id: Fixtures.appleMailTarget.id, mode: .private)
    )
    XCTAssertThrowsError(
      try model.setTargetProfile(
        id: Fixtures.appleMailTarget.id,
        profileIdentifier: nil
      )
    )

    XCTAssertEqual(model.config, before)
  }

  func testMoveMailTargetsReordersOnlyMailAndPreservesWebSortOrders() throws {
    let store = ConfigStoreStub(config: Fixtures.webAndTwoMailConfig)
    let model = makeModel(store: store, mailCatalog: .nonAuthoritative)
    try model.load()
    let webSortOrders = Dictionary(
      uniqueKeysWithValues: model.targets
        .filter { $0.routeKind == .web }
        .map { ($0.id, $0.sortOrder) }
    )

    try model.moveMailTargets(fromOffsets: IndexSet(integer: 0), toOffset: 2)

    XCTAssertEqual(
      model.mailTargets.map(\.id),
      [Fixtures.outlookTarget.id, Fixtures.appleMailTarget.id]
    )
    XCTAssertEqual(model.mailTargets.map(\.sortOrder), [0, 1])
    XCTAssertEqual(
      Dictionary(
        uniqueKeysWithValues: model.targets
          .filter { $0.routeKind == .web }
          .map { ($0.id, $0.sortOrder) }
      ),
      webSortOrders
    )
    XCTAssertEqual(store.saved.last, model.config)
  }

  func testMailEditSaveFailureLeavesModelAndPublishedSnapshotUnchanged() throws {
    let store = ConfigStoreStub(config: Fixtures.webAndMailConfig)
    let snapshot = MutableTargetSnapshot()
    let model = makeModel(
      store: store,
      mailCatalog: .nonAuthoritative,
      targetSnapshot: snapshot
    )
    try model.load()
    let before = model.config
    let publishedBefore = snapshot.availableSnapshot(for: .web)
    store.saveError = TestError.denied

    XCTAssertThrowsError(
      try model.setMailTargetEnabled(id: Fixtures.appleMailTarget.id, isEnabled: false)
    )

    XCTAssertEqual(model.config, before)
    XCTAssertEqual(snapshot.availableSnapshot(for: .web), publishedBefore)
  }

  func testEveryCanonicalTargetEditClearsPendingDefaultMigration() throws {
    let actions: [(AppModel, BrowserTarget.ID) throws -> Void] = [
      { model, id in try model.renameTarget(id: id, label: "Customized Chrome") },
      { model, id in try model.setTargetEnabled(id: id, isEnabled: false) },
      { model, id in try model.setTargetMode(id: id, mode: .normal) },
      { model, id in try model.setTargetProfile(id: id, profileIdentifier: nil) },
    ]

    for action in actions {
      let pending = Fixtures.pendingChromeDefault(sortOrder: 0)
      let model = makeModel(
        store: ConfigStoreStub(
          config: PickViaConfig(
            schemaVersion: PickViaConfig.currentSchemaVersion,
            browsers: [Fixtures.chrome],
            targets: [pending]
          )
        )
      )
      try model.load()

      try action(model, pending.id)

      XCTAssertFalse(try XCTUnwrap(model.targets.first).pendingDefaultMigration)
    }
  }

  func testReorderingClearsPendingMigrationOnlyWhenCanonicalTargetPositionChanges() throws {
    let pending = Fixtures.pendingChromeDefault(sortOrder: 0)
    let firstManual = Fixtures.manualChromeTarget(id: "manual-a", sortOrder: 1)
    let secondManual = Fixtures.manualChromeTarget(id: "manual-b", sortOrder: 2)
    let model = makeModel(
      store: ConfigStoreStub(
        config: PickViaConfig(
          schemaVersion: PickViaConfig.currentSchemaVersion,
          browsers: [Fixtures.chrome],
          targets: [pending, firstManual, secondManual]
        )
      )
    )
    try model.load()

    try model.moveTargets(fromOffsets: IndexSet(integer: 1), toOffset: 3)

    XCTAssertTrue(
      try XCTUnwrap(model.targets.first { $0.id == pending.id }).pendingDefaultMigration)

    try model.moveTargets(fromOffsets: IndexSet(integer: 0), toOffset: 3)

    XCTAssertFalse(
      try XCTUnwrap(model.targets.first { $0.id == pending.id }).pendingDefaultMigration)
  }

  func testBlankLabelIsRejectedWithoutMutatingConfig() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let model = makeModel(store: store)
    try model.load()
    let original = model.config

    XCTAssertThrowsError(try model.renameTarget(id: "work", label: "  \n"))

    XCTAssertEqual(model.config, original)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testSafariPrivateEditIsRejectedWithoutMutatingConfig() throws {
    let store = ConfigStoreStub(config: Fixtures.safariConfig)
    let model = makeModel(store: store)
    try model.load()
    let original = model.config

    XCTAssertThrowsError(try model.setTargetMode(id: "safari", mode: .private))

    XCTAssertEqual(model.config, original)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testManualTargetRequiresInstalledSupportedBrowser() throws {
    let unsupported = BrowserApplication(
      id: "com.example.browser",
      family: .chromium,
      displayName: "Example",
      bundleIdentifier: "com.example.browser",
      applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
      executableURL: URL(fileURLWithPath: "/Applications/Example.app/Contents/MacOS/Example"),
      isAvailable: true
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [unsupported], targets: [])
    let store = ConfigStoreStub(config: config)
    let model = makeModel(store: store)
    try model.load()

    XCTAssertThrowsError(
      try model.addManualTarget(
        browserID: unsupported.id,
        profileIdentifier: "Default",
        label: "Example",
        mode: .normal
      ))
    XCTAssertEqual(model.config, config)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testManualTargetRequiresKnownProfileIdentity() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let model = makeModel(store: store)
    try model.load()

    XCTAssertThrowsError(
      try model.addManualTarget(
        browserID: Fixtures.chrome.id,
        profileIdentifier: "Missing",
        label: "Missing profile",
        mode: .normal
      ))
    XCTAssertEqual(model.config, Fixtures.editableConfig)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testTargetProfileEditUsesDetectedIdentityAndDisplayName() throws {
    let manual = BrowserTarget(
      id: "manual-edit",
      browserID: Fixtures.chrome.id,
      label: "Manual",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      mode: .normal,
      isEnabled: true,
      sortOrder: 30,
      origin: .manual,
      availability: .available
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: Fixtures.profileEditConfig.browsers,
      targets: Fixtures.profileEditConfig.targets + [manual]
    )
    let store = ConfigStoreStub(config: config)
    let model = makeModel(store: store)
    try model.load()

    try model.setTargetProfile(id: manual.id, profileIdentifier: "Profile 2")

    let edited = try XCTUnwrap(model.targets.first { $0.id == manual.id })
    XCTAssertEqual(edited.profileIdentifier, "Profile 2")
    XCTAssertEqual(edited.profileDisplayName, "Personal")
    XCTAssertEqual(store.saved.last, model.config)
  }

  func testInvalidTargetProfileEditIsRejectedWithoutMutation() throws {
    let manual = BrowserTarget(
      id: "manual-invalid",
      browserID: Fixtures.chrome.id,
      label: "Manual",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      mode: .normal,
      isEnabled: true,
      sortOrder: 30,
      origin: .manual,
      availability: .available
    )
    let original = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: Fixtures.profileEditConfig.browsers,
      targets: Fixtures.profileEditConfig.targets + [manual]
    )
    let store = ConfigStoreStub(config: original)
    let model = makeModel(store: store)
    try model.load()

    XCTAssertThrowsError(try model.setTargetProfile(id: manual.id, profileIdentifier: "Missing"))

    XCTAssertEqual(model.config, original)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testDetectedTargetProfileEditIsRejectedWithoutMutation() throws {
    let store = ConfigStoreStub(config: Fixtures.profileEditConfig)
    let model = makeModel(store: store)
    try model.load()
    let original = model.config

    XCTAssertThrowsError(try model.setTargetProfile(id: "work", profileIdentifier: "Profile 2"))

    XCTAssertEqual(model.config, original)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testDetectedTargetModeEditIsRejectedWithoutMutation() throws {
    let store = ConfigStoreStub(config: Fixtures.profileEditConfig)
    let model = makeModel(store: store)
    try model.load()
    let original = model.config

    XCTAssertThrowsError(try model.setTargetMode(id: "work", mode: .private))

    XCTAssertEqual(model.config, original)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testManualTargetProfileEditSurvivesRescan() throws {
    let manual = BrowserTarget(
      id: "manual",
      browserID: Fixtures.chrome.id,
      label: "My Window",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      mode: .private,
      isEnabled: false,
      sortOrder: 41,
      origin: .manual,
      availability: .available
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: Fixtures.profileEditConfig.browsers,
      targets: Fixtures.profileEditConfig.targets + [manual]
    )
    let store = ConfigStoreStub(config: config)
    let catalog = BrowserCatalogStub(
      discovered: [],
      reconciler: {
        BrowserCatalog.reconcile(discovered: [Fixtures.discoveredChromeWithProfiles], with: $0)
      }
    )
    let model = makeModel(store: store, catalog: catalog)
    try model.load()

    try model.setTargetProfile(id: manual.id, profileIdentifier: "Profile 2")
    try model.rescan()

    let rescanned = try XCTUnwrap(model.targets.first { $0.id == manual.id })
    XCTAssertEqual(rescanned.label, "My Window")
    XCTAssertEqual(rescanned.profileIdentifier, "Profile 2")
    XCTAssertEqual(rescanned.profileDisplayName, "Personal")
    XCTAssertEqual(rescanned.mode, .private)
    XCTAssertFalse(rescanned.isEnabled)
    XCTAssertEqual(rescanned.sortOrder, 41)
    XCTAssertEqual(rescanned.origin, .manual)
    XCTAssertEqual(rescanned.availability, .available)
  }

  func testManualTargetCannotValidateAnotherManualTargetProfileIdentity() throws {
    let manualOnly = BrowserTarget(
      id: "manual-source",
      browserID: Fixtures.chrome.id,
      label: "Manual Source",
      profileIdentifier: "Profile 9",
      profileDisplayName: "Manual Only",
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .manual,
      availability: .available
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [Fixtures.chrome],
      targets: [manualOnly])
    let store = ConfigStoreStub(config: config)
    let model = makeModel(store: store)
    try model.load()

    XCTAssertThrowsError(
      try model.addManualTarget(
        browserID: Fixtures.chrome.id,
        profileIdentifier: "Profile 9",
        label: "Second Manual",
        mode: .normal
      ))
    XCTAssertEqual(model.config, config)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testBrowserProfileChoicesExposeOnlyDetectedAvailableIdentities() {
    let manual = BrowserTarget(
      id: "manual",
      browserID: Fixtures.chrome.id,
      label: "Manual",
      profileIdentifier: "Manual Profile",
      profileDisplayName: "Manual Profile",
      mode: .normal,
      isEnabled: true,
      sortOrder: 3,
      origin: .manual,
      availability: .available
    )
    let unavailable = BrowserTarget(
      id: "unavailable",
      browserID: Fixtures.chrome.id,
      label: "Unavailable",
      profileIdentifier: "Missing",
      profileDisplayName: "Missing",
      mode: .normal,
      isEnabled: true,
      sortOrder: 4,
      origin: .detected,
      availability: .unavailable
    )

    let choices = availableProfileChoices(
      browserID: Fixtures.chrome.id,
      targets: Fixtures.profileEditConfig.targets + [manual, unavailable]
    )

    XCTAssertEqual(
      choices,
      [
        BrowserProfileChoice(identifier: "Profile 1", displayName: "Work"),
        BrowserProfileChoice(identifier: "Profile 2", displayName: "Personal"),
      ])
  }

  func testValidManualTargetCanBeAddedAndRemoved() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let model = makeModel(store: store)
    try model.load()

    let id = try model.addManualTarget(
      browserID: Fixtures.chrome.id,
      profileIdentifier: "Profile 1",
      label: "Second Work",
      mode: .private
    )

    XCTAssertEqual(model.targets.last?.id, id)
    XCTAssertEqual(model.targets.last?.origin, .manual)
    XCTAssertEqual(model.targets.last?.profileDisplayName, "Work")
    try model.removeManualTarget(id: id)
    XCTAssertEqual(model.config, Fixtures.editableConfig)
    XCTAssertEqual(store.saved.count, 2)
  }

  func testFirefoxManualCreationStoresMutableNameAndDurablePickerIdentitySeparately() throws {
    let path = URL(fileURLWithPath: "/profiles/one", isDirectory: true).standardizedFileURL
    let discovered = Fixtures.discoveredFirefox(
      profiles: [
        DiscoveredProfile(
          identifier: FirefoxProfileIdentity.identifier(for: path),
          displayName: "Same Name",
          directoryURL: path,
          launchIdentifier: "Same Name"
        )
      ])
    let config = BrowserCatalog.reconcile(discovered: [discovered], with: .initial)
    let scan = BrowserScanResult(browsers: [discovered], profileAccessIssues: [])
    let model = makeModel(
      store: ConfigStoreStub(config: config),
      catalog: BrowserCatalogStub(
        scanResult: scan,
        reconciler: { BrowserCatalog.reconcile(discovered: scan.browsers, with: $0) }
      )
    )
    try model.load()

    let id = try model.addManualTarget(
      browserID: discovered.application.id,
      profileIdentifier: FirefoxProfileIdentity.identifier(for: path),
      label: "Pinned path",
      mode: .normal
    )

    let manual = try XCTUnwrap(model.targets.first { $0.id == id })
    XCTAssertEqual(manual.profileIdentifier, "Same Name")
    XCTAssertEqual(manual.profileIdentity, FirefoxProfileIdentity.identifier(for: path))
    XCTAssertEqual(manual.profileLaunchPath, path.path)
    XCTAssertEqual(manual.profileDisplayName, "Same Name")
  }

  func testFirefoxManualTargetRetainsTransientLaunchPathThroughEditsAndSnapshotButJSONOmitsIt()
    throws
  {
    let path = URL(
      fileURLWithPath: "/Users/private-user/Library/Application Support/Firefox/Profiles/one",
      isDirectory: true
    ).standardizedFileURL
    let identity = FirefoxProfileIdentity.identifier(for: path)
    let discovered = Fixtures.discoveredFirefox(
      profiles: [
        DiscoveredProfile(
          identifier: identity,
          displayName: "Work",
          directoryURL: path,
          launchIdentifier: "Work"
        )
      ])
    let config = BrowserCatalog.reconcile(discovered: [discovered], with: .initial)
    let store = ConfigStoreStub(config: config)
    let snapshot = MutableTargetSnapshot()
    let scan = BrowserScanResult(browsers: [discovered], profileAccessIssues: [])
    let model = makeModel(
      store: store,
      catalog: BrowserCatalogStub(
        scanResult: scan,
        reconciler: { BrowserCatalog.reconcile(discovered: scan.browsers, with: $0) }
      ),
      targetSnapshot: snapshot
    )
    try model.load()

    let id = try model.addManualTarget(
      browserID: discovered.application.id,
      profileIdentifier: identity,
      label: "Pinned",
      mode: .normal
    )
    try model.renameTarget(id: id, label: "Pinned Renamed")

    let manual = try XCTUnwrap(model.targets.first { $0.id == id })
    let runtime = try XCTUnwrap(
      snapshot.availableSnapshot(for: .web).targets.first { $0.id == id }
    )
    let saved = try XCTUnwrap(store.saved.last)
    let document = try XCTUnwrap(String(data: JSONEncoder().encode(saved), encoding: .utf8))
    XCTAssertEqual(manual.profileLaunchPath, path.path)
    XCTAssertEqual(runtime.profileLaunchPath, path.path)
    XCTAssertFalse(document.contains(path.path))
    XCTAssertFalse(document.contains("private-user"))
    XCTAssertFalse(document.contains("profileLaunchPath"))
  }

  func testUnprofiledManualTargetsSurviveRescanAndRemainRoutableForBothFamilies() throws {
    let firefoxPath = URL(fileURLWithPath: "/profiles/work", isDirectory: true).standardizedFileURL
    let cases = [
      Fixtures.discoveredChromeWithProfiles,
      Fixtures.discoveredFirefox(
        profiles: [
          DiscoveredProfile(
            identifier: FirefoxProfileIdentity.identifier(for: firefoxPath),
            displayName: "Work",
            directoryURL: firefoxPath,
            launchIdentifier: "Work"
          )
        ]),
    ]

    for discovered in cases {
      let initial = BrowserCatalog.reconcile(discovered: [discovered], with: .initial)
      let store = ConfigStoreStub(config: initial)
      let routing = RoutingSpy()
      let catalog = BrowserCatalogStub(
        discovered: [discovered],
        reconciler: { BrowserCatalog.reconcile(discovered: [discovered], with: $0) }
      )
      let model = makeModel(store: store, catalog: catalog, routing: routing)
      try model.load()

      let id = try model.addManualTarget(
        browserID: discovered.application.id,
        profileIdentifier: nil,
        label: "Browser Default",
        mode: .normal
      )
      try model.rescan()
      model.accept(url: URL(string: "https://example.com/route")!)

      XCTAssertEqual(
        try XCTUnwrap(model.targets.first { $0.id == id }).availability,
        .available,
        discovered.application.family.rawValue
      )
      XCTAssertEqual(routing.acceptedURLs.last, URL(string: "https://example.com/route")!)
    }
  }

  func testUnprofiledManualTargetCanBeAddedForSupportedChromiumBrowser() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let model = makeModel(store: store)
    try model.load()

    let id = try model.addManualTarget(
      browserID: Fixtures.chrome.id,
      profileIdentifier: nil,
      label: "Chrome Default",
      mode: .private
    )

    let added = try XCTUnwrap(model.targets.first { $0.id == id })
    XCTAssertNil(added.profileIdentifier)
    XCTAssertNil(added.profileIdentity)
    XCTAssertEqual(added.mode, .private)
    XCTAssertEqual(added.availability, .available)
  }

  func testManualTargetCanSwitchToUnprofiledBrowserLevelTarget() throws {
    let manual = BrowserTarget(
      id: "manual-unprofile",
      browserID: Fixtures.chrome.id,
      label: "Manual",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      mode: .normal,
      isEnabled: true,
      sortOrder: 50,
      origin: .manual,
      availability: .available
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: Fixtures.editableConfig.browsers,
      targets: Fixtures.editableConfig.targets + [manual]
    )
    let model = makeModel(store: ConfigStoreStub(config: config))
    try model.load()

    try model.setTargetProfile(id: manual.id, profileIdentifier: nil)

    let updated = try XCTUnwrap(model.targets.first { $0.id == manual.id })
    XCTAssertNil(updated.profileIdentifier)
    XCTAssertNil(updated.profileDisplayName)
    XCTAssertNil(updated.profileIdentity)
  }

  func testRemovingDetectedTargetIsRejectedWithoutMutation() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let model = makeModel(store: store)
    try model.load()

    XCTAssertThrowsError(try model.removeManualTarget(id: "work"))
    XCTAssertEqual(model.config, Fixtures.editableConfig)
    XCTAssertTrue(store.saved.isEmpty)
  }

  func testReorderingPersistsContiguousSortPositions() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let model = makeModel(store: store)
    try model.load()

    try model.moveTargets(fromOffsets: IndexSet(integer: 0), toOffset: 2)

    XCTAssertEqual(model.targets.map(\.id), ["work-private", "work"])
    XCTAssertEqual(model.targets.map(\.sortOrder), [0, 1])
    XCTAssertEqual(store.saved.last, model.config)
  }

  func testDisabledDetectedTargetRemainsDisabledAfterRescan() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig)
    let catalog = BrowserCatalogStub(
      discovered: [],
      reconciler: { BrowserCatalog.reconcile(discovered: [Fixtures.discoveredChrome], with: $0) }
    )
    let model = makeModel(store: store, catalog: catalog)
    try model.load()

    try model.setTargetEnabled(id: "work", isEnabled: false)
    try model.rescan()

    XCTAssertFalse(try XCTUnwrap(model.targets.first { $0.id == "work" }).isEnabled)
  }

  func testSaveFailureLeavesPublishedConfigUnchanged() throws {
    let store = ConfigStoreStub(config: Fixtures.editableConfig, saveError: TestError.denied)
    let model = makeModel(store: store)
    try model.load()

    XCTAssertThrowsError(try model.renameTarget(id: "work", label: "Renamed"))
    XCTAssertEqual(model.config, Fixtures.editableConfig)
  }

  private func makeModel(
    store: any ConfigStoring = ConfigStoreStub(config: .initial),
    catalog: BrowserCatalogStub = BrowserCatalogStub(),
    mailCatalog: MailCatalogStub = .missing,
    preferences: PreferencesStub = PreferencesStub(),
    defaultBrowser: DefaultBrowserSpy = DefaultBrowserSpy(),
    loginItem: LoginItemStub = LoginItemStub(),
    routing: RoutingSpy = RoutingSpy(),
    targetSnapshot: MutableTargetSnapshot? = nil,
    access: ProfileAccessManagerSpy = ProfileAccessManagerSpy(),
    profileRootValidator: BrowserProfileRootValidator = BrowserProfileRootValidator()
  ) -> AppModel {
    AppModel(
      configStore: store,
      browserCatalog: catalog,
      mailCatalog: mailCatalog,
      preferences: preferences,
      defaultBrowser: defaultBrowser,
      loginItem: loginItem,
      routing: routing,
      targetSnapshot: targetSnapshot,
      profileAccess: access,
      profileRootValidator: profileRootValidator
    )
  }

  private func makeLegacyFirefoxDiskScenario() throws -> (
    directory: URL,
    store: JSONConfigStore,
    model: AppModel,
    runtimeTargetID: RouteTarget.ID
  ) {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "pick-via-legacy-firefox-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    try Data(LegacyFirefoxDiskFixture.document.utf8).write(
      to: directory.appending(path: "PickViaConfig.json"),
      options: .atomic
    )
    let store = JSONConfigStore(directory: directory)
    let model = makeModel(
      store: store,
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(
          browsers: [],
          warnings: [],
          isAuthoritative: false
        )
      )
    )

    try model.load()

    let runtimeTarget = try XCTUnwrap(
      model.targets.first { $0.label == "Legacy Firefox" }
    )
    XCTAssertNotEqual(runtimeTarget.id, LegacyFirefoxDiskFixture.rawTargetID)
    XCTAssertEqual(
      runtimeTarget.id,
      LegacyFirefoxDiskFixture.collidingTargetID,
      "Fixture must exercise a runtime ID that collides with another authoritative target"
    )
    XCTAssertEqual(
      runtimeTarget.profileIdentity,
      LegacyFirefoxDiskFixture.canonicalProfileIdentity
    )
    XCTAssertNil(runtimeTarget.profileLaunchPath)
    XCTAssertNil(runtimeTarget.validationError)
    XCTAssertEqual(runtimeTarget.availability, .unavailable)
    XCTAssertTrue(
      try persistedDocument(in: directory).contains(LegacyFirefoxDiskFixture.rawProfilePath),
      "Load alone must not rewrite the legacy disk document"
    )
    return (directory, store, model, runtimeTarget.id)
  }

  private func assertLegacyFirefoxCanonicalization(
    _ target: RouteTarget,
    originalRuntimeTargetID: RouteTarget.ID,
    file: StaticString,
    line: UInt
  ) {
    XCTAssertNotEqual(
      target.id,
      LegacyFirefoxDiskFixture.rawTargetID,
      file: file,
      line: line
    )
    XCTAssertNotEqual(
      target.id,
      LegacyFirefoxDiskFixture.collidingTargetID,
      file: file,
      line: line
    )
    XCTAssertNotEqual(
      target.id,
      originalRuntimeTargetID,
      "The colliding runtime ID cannot replace an existing authoritative ID",
      file: file,
      line: line
    )
    XCTAssertEqual(
      target.profileIdentifier,
      "Authoritative Profile",
      file: file,
      line: line
    )
    XCTAssertEqual(
      target.profileDisplayName,
      "Authoritative Display",
      file: file,
      line: line
    )
    XCTAssertEqual(
      target.profileIdentity,
      LegacyFirefoxDiskFixture.canonicalProfileIdentity,
      file: file,
      line: line
    )
    XCTAssertEqual(
      target.validationError,
      "Authoritative validation",
      file: file,
      line: line
    )
    XCTAssertEqual(target.availability, .available, file: file, line: line)
    XCTAssertEqual(target.origin, .manual, file: file, line: line)
  }

  private func persistedDocument(in directory: URL) throws -> String {
    try XCTUnwrap(
      String(
        data: Data(contentsOf: directory.appending(path: "PickViaConfig.json")),
        encoding: .utf8
      )
    )
  }

  private func makeFirefoxRuntimeFallbackModel(
    config: PickViaConfig
  ) throws -> (model: AppModel, store: ConfigStoreStub, fallback: PickViaConfig) {
    let store = ConfigStoreStub(config: config)
    let fallback = BrowserCatalog.runtimeSanitizedFallback(config)
    let model = makeModel(
      store: store,
      catalog: BrowserCatalogStub(
        scanResult: BrowserScanResult(
          browsers: [],
          warnings: [],
          isAuthoritative: false
        )
      )
    )

    try model.load()

    XCTAssertEqual(model.config, fallback)
    XCTAssertTrue(store.saved.isEmpty)
    return (model, store, fallback)
  }

  private func assertStartupFirefoxMigrationSaveFailure(_ saveError: any Error) throws {
    let rawPath = "/Users/private-user/Library/Application Support/Firefox/Profiles/legacy-one"
    let firefox = Fixtures.installedBrowser("org.mozilla.firefox", status: .loaded).application
    let browserLevel = BrowserTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: firefox.id,
        profileIdentifier: nil,
        mode: .normal
      ),
      browserID: firefox.id,
      label: "Customized Firefox",
      profileIdentifier: nil,
      profileDisplayName: nil,
      profileIdentity: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 7,
      origin: .detected,
      availability: .available
    )
    let nameOnlyManual = BrowserTarget(
      id: "manual-name-only",
      browserID: firefox.id,
      label: "Pinned Name Only",
      profileIdentifier: "Duplicate Name",
      profileDisplayName: "Duplicate Name",
      profileIdentity: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 11,
      origin: .manual,
      availability: .available
    )
    let manualBrowserLevel = BrowserTarget(
      id: "774bb7ed-d61c-4be7-89f1-6c16daf287be",
      browserID: firefox.id,
      label: "Manual Browser Default",
      profileIdentifier: nil,
      profileDisplayName: nil,
      profileIdentity: nil,
      mode: .private,
      isEnabled: true,
      sortOrder: 9,
      origin: .manual,
      availability: .available
    )
    let rawIdentityManual = BrowserTarget(
      id: "legacy-manual|\(rawPath)|private",
      browserID: firefox.id,
      label: "Pinned Raw Identity",
      profileIdentifier: "Duplicate Name",
      profileDisplayName: "Duplicate Name",
      profileIdentity: rawPath,
      mode: .private,
      isEnabled: false,
      sortOrder: 19,
      origin: .manual,
      availability: .available
    )
    let idOnlyLegacy = BrowserTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: firefox.id,
        profileIdentifier: "/Users/private-user/Firefox/Profiles/id-only",
        mode: .normal
      ),
      browserID: firefox.id,
      label: "ID-only Legacy Profile",
      profileIdentifier: nil,
      profileDisplayName: nil,
      profileIdentity: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 23,
      origin: .detected,
      availability: .available
    )
    let detectedNameIDOnly = BrowserTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: firefox.id,
        profileIdentifier: "Legacy Name Only",
        mode: .private
      ),
      browserID: firefox.id,
      label: "Detected Name-ID-only Profile",
      profileIdentifier: nil,
      profileDisplayName: nil,
      profileIdentity: nil,
      mode: .private,
      isEnabled: true,
      sortOrder: 29,
      origin: .detected,
      availability: .available
    )
    let loaded = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [firefox],
      targets: [
        browserLevel, manualBrowserLevel, nameOnlyManual, rawIdentityManual, idOnlyLegacy,
        detectedNameIDOnly,
      ]
    )
    let discovered = Fixtures.discoveredFirefox(profiles: [
      DiscoveredProfile(
        identifier: FirefoxProfileIdentity.identifier(
          for: URL(fileURLWithPath: rawPath, isDirectory: true)
        ),
        displayName: "Duplicate Name",
        directoryURL: URL(fileURLWithPath: rawPath, isDirectory: true),
        launchIdentifier: "Duplicate Name"
      ),
      DiscoveredProfile(
        identifier: FirefoxProfileIdentity.identifier(
          for: URL(fileURLWithPath: "/Users/private-user/Firefox/Profiles/legacy-two")
        ),
        displayName: "Duplicate Name",
        directoryURL: URL(fileURLWithPath: "/Users/private-user/Firefox/Profiles/legacy-two"),
        launchIdentifier: "Duplicate Name"
      ),
    ])
    let scan = BrowserScanResult(browsers: [discovered], profileAccessIssues: [])
    let store = ConfigStoreStub(config: loaded, saveError: saveError)
    let snapshot = MutableTargetSnapshot()
    let catalog = BrowserCatalogStub(
      scanResult: scan,
      reconciler: { BrowserCatalog.reconcile(discovered: scan.browsers, with: $0) }
    )
    let model = makeModel(store: store, catalog: catalog, targetSnapshot: snapshot)

    try model.load()

    XCTAssertEqual(store.saveAttemptCount, 1)
    XCTAssertTrue(store.saved.isEmpty)
    XCTAssertEqual(store.config, loaded, "Failed startup save must leave disk state authoritative")
    XCTAssertNotNil(model.errorMessage)
    XCTAssertEqual(
      model.targets.map(\.label),
      [
        "Customized Firefox", "Manual Browser Default", "Pinned Name Only",
        "Pinned Raw Identity", "ID-only Legacy Profile", "Detected Name-ID-only Profile",
      ]
    )
    XCTAssertEqual(model.targets.map(\.isEnabled), [true, true, true, false, true, true])
    XCTAssertEqual(model.targets.map(\.sortOrder), [7, 9, 11, 19, 23, 29])
    XCTAssertEqual(model.targets[0].availability, .available)
    XCTAssertEqual(model.targets[1].availability, .available)
    XCTAssertTrue(
      model.targets.dropFirst(2).allSatisfy {
        $0.availability == .unavailable && $0.profileLaunchPath == nil
      })
    XCTAssertNil(model.targets[2].profileIdentity)
    XCTAssertTrue(
      try XCTUnwrap(model.targets[3].profileIdentity).hasPrefix(FirefoxProfileIdentity.prefix)
    )
    XCTAssertFalse(model.targets[3].id.contains("/Users"))

    XCTAssertEqual(
      snapshot.availableSnapshot(for: .web).targets,
      Array(model.targets.prefix(2))
    )

    let runtimeJSON = try XCTUnwrap(
      String(data: JSONEncoder().encode(model.config), encoding: .utf8)
    )
    XCTAssertFalse(runtimeJSON.contains(rawPath))
    XCTAssertFalse(runtimeJSON.contains("private-user"))
    XCTAssertFalse(String(describing: model.config).contains(rawPath))
  }

  private var automaticProfileAccessScan: BrowserScanResult {
    BrowserScanResult(
      browsers: [Fixtures.installedBrowser("com.google.Chrome", status: .accessRequired)],
      profileAccessIssues: [.accessRequired(bundleIdentifier: "com.google.Chrome")]
    )
  }

  private func profileRootValidator(validRoots: Set<String>) -> BrowserProfileRootValidator {
    let files = Dictionary(
      uniqueKeysWithValues: validRoots.flatMap { root in
        [
          (URL(fileURLWithPath: root).appending(path: "Local State"), Data()),
          (URL(fileURLWithPath: root).appending(path: "profiles.ini"), Data()),
        ]
      })
    return BrowserProfileRootValidator(fileSystem: ProfileRootValidatorFileSystem(files: files))
  }
}

private enum TestError: Error {
  case declined
  case denied
}

private enum Fixtures {
  static let browser = BrowserApplication(
    id: "com.example.browser",
    family: .chromium,
    displayName: "Example Browser",
    bundleIdentifier: "com.example.browser",
    applicationURL: URL(fileURLWithPath: "/Applications/Example.app"),
    executableURL: URL(fileURLWithPath: "/Applications/Example.app/Contents/MacOS/Example"),
    isAvailable: true
  )

  static func target(
    label: String = "Default",
    isEnabled: Bool = true,
    availability: BrowserTargetAvailability = .available
  ) -> BrowserTarget {
    BrowserTarget(
      id: "target",
      browserID: browser.id,
      label: label,
      profileIdentifier: "Default",
      profileDisplayName: "Default",
      mode: .normal,
      isEnabled: isEnabled,
      sortOrder: 0,
      origin: .detected,
      availability: availability
    )
  }

  static let config = PickViaConfig(
    schemaVersion: PickViaConfig.currentSchemaVersion,
    browsers: [browser],
    targets: [target()]
  )

  static let chrome = BrowserApplication(
    id: "com.google.Chrome",
    family: .chromium,
    displayName: "Google Chrome",
    bundleIdentifier: "com.google.Chrome",
    applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
    executableURL: URL(
      fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
    isAvailable: true
  )

  static let firefox = BrowserApplication(
    id: "org.mozilla.firefox",
    family: .firefox,
    displayName: "Firefox",
    bundleIdentifier: "org.mozilla.firefox",
    applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
    executableURL: URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox"),
    isAvailable: true
  )

  static func pendingFirefoxProfileTarget(
    rawPath: String,
    label: String,
    sortOrder: Int
  ) -> BrowserTarget {
    BrowserTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: firefox.id,
        profileIdentifier: rawPath,
        mode: .private
      ),
      browserID: firefox.id,
      label: label,
      profileIdentifier: "Authoritative Profile",
      profileDisplayName: "Authoritative Display",
      profileIdentity: rawPath,
      profileLaunchPath: rawPath,
      mode: .private,
      isEnabled: true,
      sortOrder: sortOrder,
      origin: .detected,
      availability: .available,
      pendingDefaultMigration: true,
      validationError: "Authoritative validation"
    )
  }

  static func firefoxRuntimeIDCollisionConfig() -> (
    config: PickViaConfig,
    first: BrowserTarget,
    second: BrowserTarget
  ) {
    let rawTargetID =
      "/Users/private-user/Library/Application Support/Firefox/Profiles/collision-first"
    let collidingAuthoritativeID =
      "firefox-runtime-target|\(FirefoxProfileIdentity.identifier(forLegacyValue: rawTargetID))"
    let first = BrowserTarget(
      id: rawTargetID,
      browserID: firefox.id,
      label: "First Authoritative",
      profileIdentifier: "First Profile",
      profileDisplayName: "First Display",
      profileIdentity: rawTargetID,
      profileLaunchPath: rawTargetID,
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .manual,
      availability: .available,
      validationError: "First validation"
    )
    let second = BrowserTarget(
      id: collidingAuthoritativeID,
      browserID: firefox.id,
      label: "Second Authoritative",
      profileIdentifier: nil,
      profileDisplayName: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 1,
      origin: .manual,
      availability: .available,
      validationError: "Second validation"
    )
    return (
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        browsers: [firefox],
        targets: [first, second]
      ),
      first,
      second
    )
  }

  static let discoveredChrome = DiscoveredBrowser(
    application: chrome,
    profiles: [DiscoveredProfile(identifier: "Profile 1", displayName: "Work", directoryURL: nil)]
  )

  static let discoveredChromeWithProfiles = DiscoveredBrowser(
    application: chrome,
    profiles: [
      DiscoveredProfile(identifier: "Profile 1", displayName: "Work", directoryURL: nil),
      DiscoveredProfile(identifier: "Profile 2", displayName: "Personal", directoryURL: nil),
    ]
  )

  static let browserConfig = editableConfig

  static let appleMail = RoutedApplication(
    id: "com.apple.mail",
    displayName: "Mail",
    bundleIdentifier: "com.apple.mail",
    capabilities: [.mail(isAvailable: true)],
    applicationURL: URL(fileURLWithPath: "/System/Applications/Mail.app")
  )

  static let outlook = RoutedApplication(
    id: "com.microsoft.Outlook",
    displayName: "Microsoft Outlook",
    bundleIdentifier: "com.microsoft.Outlook",
    capabilities: [.mail(isAvailable: true)],
    applicationURL: URL(fileURLWithPath: "/Applications/Microsoft Outlook.app")
  )

  static let appleMailDiscovery = DiscoveredMailApplication(
    bundleIdentifier: appleMail.bundleIdentifier,
    displayName: appleMail.displayName,
    applicationURL: appleMail.applicationURL
  )

  static let outlookDiscovery = DiscoveredMailApplication(
    bundleIdentifier: outlook.bundleIdentifier,
    displayName: outlook.displayName,
    applicationURL: outlook.applicationURL
  )

  static let appleMailTarget = RouteTarget(
    id: RouteTarget.mailID(bundleIdentifier: appleMail.bundleIdentifier),
    applicationID: appleMail.id,
    label: appleMail.displayName,
    isEnabled: true,
    sortOrder: 4,
    origin: .detected,
    availability: .available,
    capability: .mail
  )

  static let outlookTarget = RouteTarget(
    id: RouteTarget.mailID(bundleIdentifier: outlook.bundleIdentifier),
    applicationID: outlook.id,
    label: outlook.displayName,
    isEnabled: true,
    sortOrder: 8,
    origin: .detected,
    availability: .available,
    capability: .mail
  )

  static let mailConfig = PickViaConfig(
    schemaVersion: PickViaConfig.currentSchemaVersion,
    applications: [appleMail],
    targets: [appleMailTarget]
  )

  static let webAndMailConfig = PickViaConfig(
    schemaVersion: PickViaConfig.currentSchemaVersion,
    applications: editableConfig.applications + [appleMail],
    targets: editableConfig.targets + [appleMailTarget]
  )

  static let webAndTwoMailConfig = PickViaConfig(
    schemaVersion: PickViaConfig.currentSchemaVersion,
    applications: editableConfig.applications + [appleMail, outlook],
    targets: editableConfig.targets + [appleMailTarget, outlookTarget]
  )

  static func installedBrowser(
    _ bundleIdentifier: String,
    status: ProfileMetadataStatus,
    profiles: [DiscoveredProfile] = []
  ) -> DiscoveredBrowser {
    let descriptor = BrowserDescriptor.descriptor(forBundleIdentifier: bundleIdentifier)!
    return DiscoveredBrowser(
      application: BrowserApplication(
        id: descriptor.bundleIdentifier,
        family: descriptor.family,
        displayName: descriptor.displayName,
        bundleIdentifier: descriptor.bundleIdentifier,
        applicationURL: URL(fileURLWithPath: "/Applications/\(descriptor.displayName).app"),
        executableURL: nil,
        isAvailable: true
      ),
      profiles: profiles,
      metadataStatus: status
    )
  }

  static func discoveredFirefox(profiles: [DiscoveredProfile]) -> DiscoveredBrowser {
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

  static let editableConfig = PickViaConfig(
    schemaVersion: PickViaConfig.currentSchemaVersion,
    browsers: [chrome],
    targets: [
      BrowserTarget(
        id: "work", browserID: chrome.id, label: "Work", profileIdentifier: "Profile 1",
        profileDisplayName: "Work", mode: .normal, isEnabled: true, sortOrder: 9, origin: .detected,
        availability: .available),
      BrowserTarget(
        id: "work-private", browserID: chrome.id, label: "Work Private",
        profileIdentifier: "Profile 1", profileDisplayName: "Work", mode: .private,
        isEnabled: false, sortOrder: 20, origin: .detected, availability: .available),
    ]
  )

  static let profileEditConfig = PickViaConfig(
    schemaVersion: PickViaConfig.currentSchemaVersion,
    browsers: [chrome],
    targets: editableConfig.targets + [
      BrowserTarget(
        id: "personal", browserID: chrome.id, label: "Personal", profileIdentifier: "Profile 2",
        profileDisplayName: "Personal", mode: .normal, isEnabled: true, sortOrder: 21,
        origin: .detected, availability: .available)
    ]
  )

  static func pendingChromeDefault(sortOrder: Int) -> BrowserTarget {
    BrowserTarget(
      id: "com.google.Chrome||normal",
      browserID: chrome.id,
      label: "Google Chrome",
      profileIdentifier: nil,
      profileDisplayName: nil,
      profileIdentity: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: sortOrder,
      origin: .detected,
      availability: .available,
      pendingDefaultMigration: true
    )
  }

  static func manualChromeTarget(id: BrowserTarget.ID, sortOrder: Int) -> BrowserTarget {
    BrowserTarget(
      id: id,
      browserID: chrome.id,
      label: id,
      profileIdentifier: nil,
      profileDisplayName: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: sortOrder,
      origin: .manual,
      availability: .available
    )
  }

  static let safariConfig = PickViaConfig(
    schemaVersion: PickViaConfig.currentSchemaVersion,
    browsers: [
      BrowserApplication(
        id: "com.apple.Safari", family: .safari, displayName: "Safari",
        bundleIdentifier: "com.apple.Safari",
        applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"), executableURL: nil,
        isAvailable: true)
    ],
    targets: [
      BrowserTarget(
        id: "safari", browserID: "com.apple.Safari", label: "Safari", profileIdentifier: nil,
        profileDisplayName: nil, mode: .normal, isEnabled: true, sortOrder: 0, origin: .detected,
        availability: .available)
    ]
  )

  static func copy(_ target: BrowserTarget, label: String) -> BrowserTarget {
    BrowserTarget(
      id: target.id,
      browserID: target.browserID,
      label: label,
      profileIdentifier: target.profileIdentifier,
      profileDisplayName: target.profileDisplayName,
      profileIdentity: target.profileIdentity,
      profileLaunchPath: target.profileLaunchPath,
      mode: target.mode,
      isEnabled: target.isEnabled,
      sortOrder: target.sortOrder,
      origin: target.origin,
      availability: target.availability
    )
  }

  static func copy(
    _ application: RoutedApplication,
    mailIsAvailable: Bool
  ) -> RoutedApplication {
    RoutedApplication(
      id: application.id,
      displayName: application.displayName,
      bundleIdentifier: application.bundleIdentifier,
      capabilities: application.capabilities.map { capability in
        capability.routeKind == .mail
          ? .mail(isAvailable: mailIsAvailable)
          : capability
      },
      applicationURL: application.applicationURL,
      browserExecutableURL: application.browserExecutableURL
    )
  }
}

private final class ConfigStoreStub: ConfigStoring, @unchecked Sendable {
  var config: PickViaConfig
  private(set) var loadCallCount = 0
  private(set) var saved: [PickViaConfig] = []
  private(set) var saveAttemptCount = 0
  var saveError: Error?
  let configuredLoadOutcome: ConfigLoadOutcome?

  init(
    config: PickViaConfig,
    saveError: Error? = nil,
    loadOutcome: ConfigLoadOutcome? = nil
  ) {
    self.config = config
    self.saveError = saveError
    self.configuredLoadOutcome = loadOutcome
  }
  func loadOutcome() -> ConfigLoadOutcome {
    loadCallCount += 1
    return configuredLoadOutcome ?? .loaded(config)
  }
  func load() throws -> PickViaConfig {
    loadCallCount += 1
    return config
  }
  func save(_ config: PickViaConfig) throws {
    saveAttemptCount += 1
    if let saveError { throw saveError }
    saved.append(config)
  }
  func resetSaved() { saved.removeAll() }
}

private final class FailOnceConfigStore: ConfigStoring, @unchecked Sendable {
  private let wrapped: any ConfigStoring
  private var error: Error?

  init(wrapping wrapped: any ConfigStoring, error: any Error) {
    self.wrapped = wrapped
    self.error = error
  }

  func load() throws -> PickViaConfig {
    try wrapped.load()
  }

  func loadOutcome() -> ConfigLoadOutcome {
    wrapped.loadOutcome()
  }

  func save(_ config: PickViaConfig) throws {
    if let error {
      self.error = nil
      throw error
    }
    try wrapped.save(config)
  }
}

private final class BrowserCatalogStub: BrowserDiscovering, @unchecked Sendable {
  var discovered: [DiscoveredBrowser]
  var reconciled: PickViaConfig
  private(set) var reconcileInputs: [PickViaConfig] = []
  private let reconciler: ((PickViaConfig) -> PickViaConfig)?
  private var configuredScanResult: BrowserScanResult?
  private let targeted: [String: DiscoveredBrowser]
  private(set) var scanResultCallCount = 0
  private(set) var targetedScanBundleIdentifiers: [String] = []

  init(
    discovered: [DiscoveredBrowser] = [],
    reconciled: PickViaConfig = .initial,
    scanResult: BrowserScanResult? = nil,
    targeted: [String: DiscoveredBrowser] = [:],
    reconciler: ((PickViaConfig) -> PickViaConfig)? = nil
  ) {
    self.discovered = discovered
    self.reconciled = reconciled
    self.reconciler = reconciler
    self.configuredScanResult = scanResult
    self.targeted = targeted
  }
  func scanResult(for bundleIdentifier: String) -> DiscoveredBrowser? {
    targetedScanBundleIdentifiers.append(bundleIdentifier)
    return targeted[bundleIdentifier]
  }

  func scan() throws -> [DiscoveredBrowser] { discovered }
  func scanResult() -> BrowserScanResult {
    scanResultCallCount += 1
    return configuredScanResult
      ?? BrowserScanResult(
        browsers: discovered,
        warnings: [],
        isAuthoritative: !discovered.isEmpty || reconciled != .initial
      )
  }
  func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig {
    reconcileInputs.append(config)
    return reconciler?(config) ?? reconciled
  }
  func resetReconcileInputs() { reconcileInputs.removeAll() }
  func resetScanCalls() { scanResultCallCount = 0 }
  func resetTargetedScanCalls() { targetedScanBundleIdentifiers.removeAll() }
  func setScanResult(_ scanResult: BrowserScanResult) { configuredScanResult = scanResult }
}

private final class MailCatalogStub: MailDiscovering, @unchecked Sendable {
  private var configuredScan: MailScanResult
  private let reconciler: ((MailScanResult, PickViaConfig) -> PickViaConfig)?
  private let fallback: PickViaConfig?
  private(set) var scanResultCallCount = 0
  private(set) var reconcileInputs: [PickViaConfig] = []
  private(set) var runtimeFallbackInputs: [PickViaConfig] = []

  init(
    scan: MailScanResult,
    runtimeFallback: PickViaConfig? = nil,
    reconciler: ((MailScanResult, PickViaConfig) -> PickViaConfig)? = nil
  ) {
    configuredScan = scan
    fallback = runtimeFallback
    self.reconciler = reconciler
  }

  static func authoritative(
    _ applications: [DiscoveredMailApplication]
  ) -> MailCatalogStub {
    MailCatalogStub(
      scan: MailScanResult(applications: applications, isAuthoritative: true)
    )
  }

  static var nonAuthoritative: MailCatalogStub {
    MailCatalogStub(
      scan: MailScanResult(applications: [], isAuthoritative: false)
    )
  }

  static var missing: MailCatalogStub {
    .authoritative([])
  }

  func scanResult() -> MailScanResult {
    scanResultCallCount += 1
    return configuredScan
  }

  func reconcile(_ scan: MailScanResult, with config: PickViaConfig) -> PickViaConfig {
    reconcileInputs.append(config)
    return reconciler?(scan, config) ?? MailCatalog.reconcile(scan, with: config)
  }

  func runtimeSanitizedFallback(_ config: PickViaConfig) -> PickViaConfig {
    runtimeFallbackInputs.append(config)
    return fallback ?? config
  }

  func setScan(_ scan: MailScanResult) {
    configuredScan = scan
  }
}

private final class ProfileAccessManagerSpy: ProfileAccessManaging, @unchecked Sendable {
  private var persistenceByBundleIdentifier: [String: ProfileGrantPersistence]
  private let installOutcome: ProfileGrantPersistence
  private let installError: Error?
  private(set) var installed: [(root: URL, bundleIdentifier: String)] = []
  private(set) var removedBundleIdentifiers: [String] = []

  init(
    persistence: [String: ProfileGrantPersistence] = [:],
    installOutcome: ProfileGrantPersistence = .persistent,
    installError: Error? = nil
  ) {
    persistenceByBundleIdentifier = persistence
    self.installOutcome = installOutcome
    self.installError = installError
  }

  func beginAccess(for bundleIdentifier: String) -> ProfileRootAccessResult {
    ProfileRootAccessResult(state: .missing, lease: nil)
  }

  func installGrant(
    root: URL,
    for bundleIdentifier: String
  ) throws -> ProfileGrantPersistence {
    installed.append((root, bundleIdentifier))
    if let installError { throw installError }
    persistenceByBundleIdentifier[bundleIdentifier] = installOutcome
    return installOutcome
  }

  func persistence(for bundleIdentifier: String) -> ProfileGrantPersistence? {
    persistenceByBundleIdentifier[bundleIdentifier]
  }

  func removeGrant(for bundleIdentifier: String) throws {
    removedBundleIdentifiers.append(bundleIdentifier)
    persistenceByBundleIdentifier[bundleIdentifier] = nil
  }
}

private final class ProfileRootValidatorFileSystem: FileSystem, @unchecked Sendable {
  let files: [URL: Data]

  init(files: [URL: Data]) {
    self.files = files
  }

  func createDirectory(at url: URL) throws {}
  func fileExists(at url: URL) -> Bool { files[url] != nil }
  func read(from url: URL) throws -> Data {
    guard let data = files[url] else { throw CocoaError(.fileReadNoSuchFile) }
    return data
  }
  func writeAtomically(_ data: Data, to url: URL) throws {}
  func moveItem(at source: URL, to destination: URL) throws {}
  func replaceItem(at destination: URL, with source: URL) throws {}
}

@MainActor
private final class PreferencesStub: PreferencesStoring {
  var booleans: [String: Bool]
  var integers: [String: Int]
  private(set) var setBooleans: [String: Bool] = [:]
  private(set) var setIntegers: [String: Int] = [:]

  init(booleans: [String: Bool] = [:], integers: [String: Int] = [:]) {
    self.booleans = booleans
    self.integers = integers
  }

  func bool(forKey key: String) -> Bool? { booleans[key] }
  func integer(forKey key: String) -> Int? { integers[key] }
  func set(_ value: Bool, forKey key: String) {
    setBooleans[key] = value
    booleans[key] = value
  }
  func set(_ value: Int, forKey key: String) {
    setIntegers[key] = value
    integers[key] = value
  }
}

@MainActor
private final class DefaultBrowserSpy: DefaultHandlerServicing {
  var statuses: [DefaultHandlerStatus]
  var requestError: Error?
  private(set) var statusCallCount = 0
  private(set) var requestedSchemes: [String] = []

  init(
    status: DefaultHandlerStatus = .unknown,
    requestError: Error? = nil
  ) {
    statuses = [status]
    self.requestError = requestError
  }

  init(statuses: [DefaultHandlerStatus], requestError: Error? = nil) {
    precondition(!statuses.isEmpty)
    self.statuses = statuses
    self.requestError = requestError
  }

  func status() -> DefaultHandlerStatus {
    let index = min(statusCallCount, statuses.count - 1)
    statusCallCount += 1
    return statuses[index]
  }
  func requestDefault(for schemes: [String]) async throws {
    requestedSchemes.append(contentsOf: schemes)
    if let requestError { throw requestError }
  }
}

@MainActor
private final class LoginItemStub: LoginItemServicing {
  var isEnabled: Bool
  var setError: Error?
  private(set) var requestedValues: [Bool] = []

  init(isEnabled: Bool = false, setError: Error? = nil) {
    self.isEnabled = isEnabled
    self.setError = setError
  }

  func setEnabled(_ enabled: Bool) throws {
    requestedValues.append(enabled)
    if let setError { throw setError }
    isEnabled = enabled
  }
}

@MainActor
private final class RoutingSpy: AppRouting {
  private(set) var acceptedURLs: [URL] = []
  private(set) var previewedURLs: [URL] = []
  private(set) var refreshCallCount = 0

  func accept(_ url: URL) { acceptedURLs.append(url) }
  func preview(_ url: URL) { previewedURLs.append(url) }
  func refreshCurrent() { refreshCallCount += 1 }
}
