import Foundation
import XCTest

@testable import PickViaCore

final class ConfigStoreTests: XCTestCase {
  func testLoadOutcomeDistinguishesMissingLoadedAndRecoveredCorruption() throws {
    let missingDirectory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: missingDirectory) }
    let missingStore = JSONConfigStore(directory: missingDirectory)
    XCTAssertEqual(missingStore.loadOutcome(), .missing(.initial))

    try missingStore.save(.initial)
    XCTAssertEqual(missingStore.loadOutcome(), .loaded(.initial))

    let fileURL = missingDirectory.appending(path: "PickViaConfig.json")
    try Data("not json".utf8).write(to: fileURL)
    XCTAssertEqual(missingStore.loadOutcome(), .recoveredCorruption(.initial))
  }

  func testReadFailureIsTypedAndDoesNotPublishDefaults() {
    let store = JSONConfigStore(
      directory: URL(fileURLWithPath: "/virtual/application-support"),
      fileSystem: ReadFailingFileSystem()
    )

    XCTAssertEqual(store.loadOutcome(), .failure(.readFailed))
  }

  func testFutureSchemaAndSemanticCorruptionAreQuarantined() throws {
    let corruptConfigurations = [
      PickViaConfig(schemaVersion: 99, browsers: [], targets: []),
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        browsers: [validChrome, validChrome],
        targets: []
      ),
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        browsers: [validChrome],
        targets: [copyTarget(validTarget, id: "blank-label", label: "  ")]
      ),
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        browsers: [validChrome],
        targets: [validTarget, validTarget]
      ),
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        browsers: [validChrome],
        targets: [copyTarget(validTarget, id: "mismatch", browserID: "missing-browser")]
      ),
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        browsers: [validChrome],
        targets: [copyTarget(validTarget, id: "bad-profile", profileIdentity: "  ")]
      ),
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        browsers: [validSafari],
        targets: [validSafariTargetWithMetadata]
      ),
    ]

    for config in corruptConfigurations {
      let directory = try temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let fileURL = directory.appending(path: "PickViaConfig.json")
      try JSONEncoder().encode(config).write(to: fileURL)
      let store = JSONConfigStore(directory: directory)

      XCTAssertEqual(store.loadOutcome(), .recoveredCorruption(.initial))
      XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }
  }

  func testSchemaZeroDocumentMigratesToCurrentSchema() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = PickViaConfig(schemaVersion: 0, browsers: [validChrome], targets: [validTarget])
    try JSONEncoder().encode(legacy).write(
      to: directory.appending(path: "PickViaConfig.json"))

    let outcome = JSONConfigStore(directory: directory).loadOutcome()

    guard case .loaded(let migrated) = outcome else {
      return XCTFail("Expected a loaded migrated document")
    }
    XCTAssertEqual(migrated.schemaVersion, PickViaConfig.currentSchemaVersion)
    XCTAssertEqual(migrated.browsers.map(\.id), legacy.browsers.map(\.id))
    XCTAssertEqual(migrated.targets, legacy.targets)
  }

  func testLegacyBrowserFamiliesDecodeUnchanged() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = Data(
      """
      {
        "schemaVersion": 2,
        "browsers": [
          {
            "id": "com.apple.Safari",
            "family": "safari",
            "displayName": "Safari",
            "bundleIdentifier": "com.apple.Safari",
            "isAvailable": true
          },
          {
            "id": "com.duckduckgo.macos.browser",
            "family": "duckDuckGo",
            "displayName": "DuckDuckGo",
            "bundleIdentifier": "com.duckduckgo.macos.browser",
            "isAvailable": true
          },
          {
            "id": "com.google.Chrome",
            "family": "chromium",
            "displayName": "Google Chrome",
            "bundleIdentifier": "com.google.Chrome",
            "isAvailable": true
          },
          {
            "id": "org.mozilla.firefox",
            "family": "firefox",
            "displayName": "Firefox",
            "bundleIdentifier": "org.mozilla.firefox",
            "isAvailable": true
          }
        ],
        "targets": []
      }
      """.utf8
    )
    try data.write(to: directory.appending(path: "PickViaConfig.json"))

    let loaded = try JSONConfigStore(directory: directory).load()

    XCTAssertEqual(
      loaded.browsers.map(\.family),
      [.safari, .duckDuckGo, .chromium, .firefox]
    )
    XCTAssertEqual(
      loaded.browsers.map(\.id),
      [
        "com.apple.Safari",
        "com.duckduckgo.macos.browser",
        "com.google.Chrome",
        "org.mozilla.firefox",
      ]
    )
  }

  func testNewBrowserFamiliesRoundTripUnchanged() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let applications = [
      channelApplication(
        id: "com.operasoftware.Opera",
        family: .opera,
        displayName: "Opera",
        executableName: nil
      ),
      channelApplication(
        id: "company.thebrowser.Browser",
        family: .arc,
        displayName: "Arc",
        executableName: nil
      ),
      channelApplication(
        id: "com.kagi.kagimacOS",
        family: .orion,
        displayName: "Orion",
        executableName: nil
      ),
    ]
    let targets = applications.enumerated().map { index, application in
      BrowserTarget(
        id: BrowserCatalog.targetID(
          bundleIdentifier: application.bundleIdentifier,
          profileIdentifier: nil,
          mode: .normal
        ),
        browserID: application.id,
        label: application.displayName,
        profileIdentifier: nil,
        profileDisplayName: nil,
        mode: .normal,
        isEnabled: true,
        sortOrder: index,
        origin: .detected,
        availability: .available
      )
    }
    let expected = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: applications,
      targets: targets
    )
    let store = JSONConfigStore(directory: directory)

    try store.save(expected)
    let loaded = try store.load()

    XCTAssertEqual(loaded.browsers.map(\.id), expected.browsers.map(\.id))
    XCTAssertEqual(loaded.browsers.map(\.family), [.opera, .arc, .orion])
    XCTAssertEqual(loaded.browsers.map(\.displayName), expected.browsers.map(\.displayName))
    XCTAssertEqual(loaded.targets, expected.targets)
  }

  func testUnknownBrowserFamilyRetainsCorruptionRecovery() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "PickViaConfig.json")
    let data = Data(
      """
      {
        "schemaVersion": 2,
        "browsers": [
          {
            "id": "com.example.unknown",
            "family": "unknown-browser-family",
            "displayName": "Unknown",
            "bundleIdentifier": "com.example.unknown",
            "isAvailable": true
          }
        ],
        "targets": []
      }
      """.utf8
    )
    try data.write(to: fileURL)

    let outcome = JSONConfigStore(
      directory: directory,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    ).loadOutcome()

    XCTAssertEqual(outcome, .recoveredCorruption(.initial))
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: directory.appending(path: "PickViaConfig.json.corrupt-1700000000").path
      )
    )
  }

  func testNewChannelApplicationsAndTargetIDsRoundTripUnchanged() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let applications = [validChrome] + newChannelApplications
    let channelTargets = newChannelApplications.enumerated().map { index, application in
      BrowserTarget(
        id: BrowserCatalog.targetID(
          bundleIdentifier: application.bundleIdentifier,
          profileIdentifier: nil,
          mode: .normal
        ),
        browserID: application.id,
        label: application.displayName,
        profileIdentifier: nil,
        profileDisplayName: nil,
        mode: .normal,
        isEnabled: true,
        sortOrder: index + 1,
        origin: .detected,
        availability: .available
      )
    }
    let expected = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: applications,
      targets: [validTarget] + channelTargets
    )
    let store = JSONConfigStore(directory: directory)

    try store.save(expected)
    let loaded = try store.load()

    XCTAssertEqual(loaded.browsers.map(\.id), expected.browsers.map(\.id))
    XCTAssertEqual(loaded.browsers.map(\.family), expected.browsers.map(\.family))
    XCTAssertEqual(loaded.browsers.map(\.displayName), expected.browsers.map(\.displayName))
    XCTAssertEqual(loaded.targets.map(\.id), expected.targets.map(\.id))
    XCTAssertEqual(loaded.targets.first?.id, validTarget.id)
  }

  func testSchemaOneNormalizesDetectedTargetEnabledStatesOnce() throws {
    let browser = validChrome
    let detected = [
      makeTarget(id: "default-normal", profile: nil, mode: .normal, enabled: false),
      makeTarget(id: "default-private", profile: nil, mode: .private, enabled: false),
      makeTarget(id: "work-normal", profile: "Profile 1", mode: .normal, enabled: false),
      makeTarget(id: "work-private", profile: "Profile 1", mode: .private, enabled: true),
    ]
    let manual = makeTarget(
      id: "manual-private",
      profile: "Profile 1",
      mode: .private,
      enabled: true,
      origin: .manual
    )

    let migrated = try PickViaConfig(
      schemaVersion: 1,
      browsers: [browser],
      targets: detected + [manual]
    ).validatedAndMigrated()

    XCTAssertEqual(migrated.schemaVersion, PickViaConfig.currentSchemaVersion)
    XCTAssertEqual(migrated.targets.map(\.isEnabled), [true, true, true, false, true])
    XCTAssertEqual(
      migrated.targets.map(\.pendingDefaultMigration),
      [false, false, false, true, false]
    )
  }

  func testCurrentSchemaPreservesDetectedEnabledStates() throws {
    let target = makeTarget(
      id: "default-private",
      profile: nil,
      mode: .private,
      enabled: false
    )
    let validated = try PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [validChrome],
      targets: [target]
    ).validatedAndMigrated()

    XCTAssertFalse(validated.targets[0].isEnabled)
  }

  func testMissingFileReturnsInitialConfiguration() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(directory: directory)

    XCTAssertEqual(try store.load(), .initial)
  }

  func testSaveThenLoadRoundTripsConfiguration() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(
      directory: directory,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )
    let target = copyTarget(validTarget, label: "工作")
    let expected = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [validChrome], targets: [target])

    try store.save(expected)

    let loaded = try store.load()
    XCTAssertEqual(loaded.schemaVersion, expected.schemaVersion)
    XCTAssertEqual(loaded.targets, expected.targets)
    XCTAssertEqual(loaded.browsers.map(\.id), expected.browsers.map(\.id))
    XCTAssertEqual(loaded.browsers.map(\.displayName), expected.browsers.map(\.displayName))
  }

  func testSaveSkipsFirefoxProfileValidationForMailTarget() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let application = RoutedApplication(
      id: "org.mozilla.firefox",
      displayName: "Firefox",
      bundleIdentifier: "org.mozilla.firefox",
      capabilities: [
        .browser(family: .firefox, isAvailable: true),
        .mail(isAvailable: true),
      ],
      applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
      browserExecutableURL: URL(
        fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox")
    )
    let mailTarget = RouteTarget(
      id: RouteTarget.mailID(bundleIdentifier: application.bundleIdentifier),
      applicationID: application.id,
      label: "Firefox Mail",
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available,
      capability: .mail
    )
    let expected = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [application],
      targets: [mailTarget]
    )

    let store = JSONConfigStore(directory: directory)
    try store.save(expected)

    XCTAssertEqual(try store.load().targets, [mailTarget])
  }

  func testSavedDocumentDoesNotPersistApplicationOrExecutablePaths() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(directory: directory)

    try store.save(
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [validChrome],
        targets: [validTarget])
    )

    let data = try Data(contentsOf: directory.appending(path: "PickViaConfig.json"))
    let document = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(document.contains("/Applications"))
    XCTAssertFalse(document.contains("applicationURL"))
    XCTAssertFalse(document.contains("executableURL"))
  }

  func testTargetCodableOmitsTransientFirefoxLaunchPathAndDecodeClearsIt() throws {
    let launchPath = "/Users/private-user/Library/Application Support/Firefox/Profiles/work"
    let profileIdentity = FirefoxProfileIdentity.identifier(
      for: URL(fileURLWithPath: launchPath, isDirectory: true)
    )
    let target = BrowserTarget(
      id: "org.mozilla.firefox|\(profileIdentity)|normal",
      browserID: "org.mozilla.firefox",
      label: "Work",
      profileIdentifier: "Work",
      profileDisplayName: "Work",
      profileIdentity: profileIdentity,
      profileLaunchPath: launchPath,
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available
    )

    let data = try JSONEncoder().encode(target)
    let document = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(document.contains(launchPath))
    XCTAssertFalse(document.contains("private-user"))
    XCTAssertFalse(document.contains("profileLaunchPath"))

    let decoded = try JSONDecoder().decode(BrowserTarget.self, from: data)
    XCTAssertEqual(decoded.profileIdentity, target.profileIdentity)
    XCTAssertNil(decoded.profileLaunchPath)
  }

  func testPendingDefaultMigrationCodableIsBackwardCompatibleAndPersistsOnlyWhenSet() throws {
    let legacyData = try JSONEncoder().encode(validTarget)
    let legacyDocument = try XCTUnwrap(String(data: legacyData, encoding: .utf8))
    XCTAssertFalse(legacyDocument.contains("pendingDefaultMigration"))
    XCTAssertFalse(
      try JSONDecoder().decode(BrowserTarget.self, from: legacyData).pendingDefaultMigration)

    let pending = BrowserTarget(
      id: "com.google.Chrome||normal",
      browserID: validChrome.id,
      label: "Google Chrome",
      profileIdentifier: nil,
      profileDisplayName: nil,
      profileIdentity: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 3,
      origin: .detected,
      availability: .available,
      pendingDefaultMigration: true
    )
    let pendingData = try JSONEncoder().encode(pending)
    let pendingDocument = try XCTUnwrap(String(data: pendingData, encoding: .utf8))

    XCTAssertTrue(pendingDocument.contains("\"pendingDefaultMigration\":true"))
    XCTAssertTrue(
      try JSONDecoder().decode(BrowserTarget.self, from: pendingData).pendingDefaultMigration)
  }

  func testPendingDefaultMigrationValidationIsLimitedToDetectedMigrationTargets()
    throws
  {
    let validPendingTargets = [
      BrowserTarget(
        id: "com.google.Chrome||private",
        browserID: validChrome.id,
        label: "Google Chrome Private",
        profileIdentifier: nil,
        profileDisplayName: nil,
        profileIdentity: nil,
        mode: .private,
        isEnabled: false,
        sortOrder: 0,
        origin: .detected,
        availability: .available,
        pendingDefaultMigration: true
      ),
      BrowserTarget(
        id: "com.google.Chrome|Default|private",
        browserID: validChrome.id,
        label: "Personal Private",
        profileIdentifier: "Default",
        profileDisplayName: "Personal",
        profileIdentity: "Default",
        mode: .private,
        isEnabled: false,
        sortOrder: 1,
        origin: .detected,
        availability: .available,
        pendingDefaultMigration: true
      ),
    ]
    for target in validPendingTargets {
      XCTAssertTrue(
        try PickViaConfig(
          schemaVersion: PickViaConfig.currentSchemaVersion,
          browsers: [validChrome],
          targets: [target]
        ).validatedAndMigrated().targets[0].pendingDefaultMigration
      )
    }

    let invalidTargets = [
      BrowserTarget(
        id: "manual",
        browserID: validChrome.id,
        label: "Manual",
        profileIdentifier: nil,
        profileDisplayName: nil,
        mode: .normal,
        isEnabled: true,
        sortOrder: 0,
        origin: .manual,
        availability: .available,
        pendingDefaultMigration: true
      ),
      BrowserTarget(
        id: "com.google.Chrome|Default|normal",
        browserID: validChrome.id,
        label: "Personal",
        profileIdentifier: "Default",
        profileDisplayName: "Personal",
        profileIdentity: "Default",
        mode: .normal,
        isEnabled: true,
        sortOrder: 0,
        origin: .detected,
        availability: .available,
        pendingDefaultMigration: true
      ),
      BrowserTarget(
        id: "com.google.Chrome|missing-profile|private",
        browserID: validChrome.id,
        label: "Malformed Private",
        profileIdentifier: nil,
        profileDisplayName: nil,
        profileIdentity: nil,
        profileLaunchPath: nil,
        mode: .private,
        isEnabled: false,
        sortOrder: 0,
        origin: .detected,
        availability: .available,
        pendingDefaultMigration: true
      ),
      BrowserTarget(
        id: "com.apple.Safari||normal",
        browserID: validSafari.id,
        label: "Safari",
        profileIdentifier: nil,
        profileDisplayName: nil,
        mode: .normal,
        isEnabled: true,
        sortOrder: 0,
        origin: .detected,
        availability: .available,
        pendingDefaultMigration: true
      ),
    ]

    for target in invalidTargets {
      let browsers = target.browserID == validSafari.id ? [validSafari] : [validChrome]
      XCTAssertThrowsError(
        try PickViaConfig(
          schemaVersion: PickViaConfig.currentSchemaVersion,
          browsers: browsers,
          targets: [target]
        ).validatedAndMigrated()
      )
    }
  }

  func testBrowserTargetValidationUsesDescriptorStrategiesInsteadOfFamily() throws {
    let shortcut = BrowserDescriptor(
      bundleIdentifier: "com.example.future-safari-shortcut",
      family: .safari,
      displayName: "Future Safari Shortcut",
      profileStrategy: .safariShortcut,
      launchStrategy: .workspace,
      privateStrategy: .safariShortcut
    )
    let shortcutApplication = descriptorApplication(shortcut)
    let enhancedShortcutTarget = BrowserTarget(
      id: "future-shortcut-target",
      browserID: shortcutApplication.id,
      label: "Future Safari Work Private",
      profileIdentifier: "PickVia Safari Work",
      profileDisplayName: "Work",
      profileIdentity: "shortcut:pickvia-safari-work",
      mode: .private,
      isEnabled: true,
      sortOrder: 0,
      origin: .manual,
      availability: .available
    )

    let validatedShortcut = try PickViaConfig(
      schemaVersion: 1,
      browsers: [shortcutApplication],
      targets: [enhancedShortcutTarget]
    ).validatedAndMigrated(descriptors: [shortcut])

    XCTAssertEqual(validatedShortcut.targets, [enhancedShortcutTarget])
    XCTAssertFalse(validatedShortcut.targets[0].pendingDefaultMigration)
    XCTAssertTrue(validatedShortcut.targets[0].isEnabled)

    let operaFamilyFileBacked = BrowserDescriptor(
      bundleIdentifier: "com.example.opera-family-file-backed",
      family: .opera,
      displayName: "Opera Family File Backed",
      profileStrategy: .chromium(root: "Synthetic Opera"),
      launchStrategy: .chromium(
        executableRelativePath: "Contents/MacOS/synthetic",
        profileArgument: "--profile="
      ),
      privateStrategy: .argument("--private")
    )
    let fileBackedApplication = descriptorApplication(operaFamilyFileBacked)
    let legacyPrivateProfile = BrowserTarget(
      id: "com.example.opera-family-file-backed|Profile 1|private",
      browserID: fileBackedApplication.id,
      label: "Legacy private profile",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      profileIdentity: "Profile 1",
      mode: .private,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available
    )
    let migratedByStrategy = try PickViaConfig(
      schemaVersion: 1,
      browsers: [fileBackedApplication],
      targets: [legacyPrivateProfile]
    ).validatedAndMigrated(descriptors: [operaFamilyFileBacked])

    XCTAssertTrue(migratedByStrategy.targets[0].pendingDefaultMigration)
    XCTAssertFalse(migratedByStrategy.targets[0].isEnabled)

    let familyClaimsEnhancement = BrowserDescriptor(
      bundleIdentifier: "com.example.chromium-family-normal-only",
      family: .chromium,
      displayName: "Chromium Family Normal Only",
      profileStrategy: .none,
      launchStrategy: .workspace,
      privateStrategy: .unsupported
    )
    let normalOnlyApplication = descriptorApplication(familyClaimsEnhancement)
    let rejectedTargets = [
      BrowserTarget(
        id: "family-only-profile",
        browserID: normalOnlyApplication.id,
        label: "Profile",
        profileIdentifier: "Profile 1",
        profileDisplayName: "Work",
        mode: .normal,
        isEnabled: true,
        sortOrder: 0,
        origin: .manual,
        availability: .available
      ),
      BrowserTarget(
        id: "family-only-private",
        browserID: normalOnlyApplication.id,
        label: "Private",
        profileIdentifier: nil,
        profileDisplayName: nil,
        mode: .private,
        isEnabled: true,
        sortOrder: 0,
        origin: .manual,
        availability: .available
      ),
    ]
    for target in rejectedTargets {
      XCTAssertThrowsError(
        try PickViaConfig(
          schemaVersion: PickViaConfig.currentSchemaVersion,
          browsers: [normalOnlyApplication],
          targets: [target]
        ).validatedAndMigrated(descriptors: [familyClaimsEnhancement])
      )
    }
  }

  func testStoreAppliesFirefoxPersistencePolicyByProfileStrategyNotFamily() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firefoxFamilyNormalOnly = BrowserDescriptor(
      bundleIdentifier: "com.example.firefox-family-normal-only",
      family: .firefox,
      displayName: "Firefox Family Normal Only",
      profileStrategy: .none,
      launchStrategy: .workspace,
      privateStrategy: .unsupported
    )
    let normalOnlyApplication = descriptorApplication(firefoxFamilyNormalOnly)
    let pathShapedBrowserLevel = BrowserTarget(
      id: "/synthetic/manual-browser-level-id",
      browserID: normalOnlyApplication.id,
      label: "Browser level",
      profileIdentifier: nil,
      profileDisplayName: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .manual,
      availability: .available
    )
    let normalOnlyStore = JSONConfigStore(
      directory: directory.appending(path: "normal-only"),
      browserDescriptors: [firefoxFamilyNormalOnly]
    )

    XCTAssertNoThrow(
      try normalOnlyStore.save(
        PickViaConfig(
          schemaVersion: PickViaConfig.currentSchemaVersion,
          browsers: [normalOnlyApplication],
          targets: [pathShapedBrowserLevel]
        )
      )
    )

    let chromiumFamilyFirefoxStrategy = BrowserDescriptor(
      bundleIdentifier: "com.example.chromium-family-firefox-strategy",
      family: .chromium,
      displayName: "Chromium Family Firefox Strategy",
      profileStrategy: .firefox(root: "Synthetic Firefox"),
      launchStrategy: .firefox(executableRelativePath: "Contents/MacOS/firefox"),
      privateStrategy: .argument("-private-window")
    )
    let firefoxStrategyApplication = descriptorApplication(chromiumFamilyFirefoxStrategy)
    let unsafeFirefoxStrategyTarget = BrowserTarget(
      id: "/synthetic/unsafe-firefox-target-id",
      browserID: firefoxStrategyApplication.id,
      label: "Unsafe",
      profileIdentifier: nil,
      profileDisplayName: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .manual,
      availability: .available
    )
    let firefoxStrategyStore = JSONConfigStore(
      directory: directory.appending(path: "firefox-strategy"),
      browserDescriptors: [chromiumFamilyFirefoxStrategy]
    )

    XCTAssertThrowsError(
      try firefoxStrategyStore.save(
        PickViaConfig(
          schemaVersion: PickViaConfig.currentSchemaVersion,
          browsers: [firefoxStrategyApplication],
          targets: [unsafeFirefoxStrategyTarget]
        )
      )
    )
  }

  func testSavedFirefoxConfigurationContainsNoSelectedRootUsernameOrAbsoluteProfilePath() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let selectedRoot = "/Users/private-user/Library/Application Support/Firefox"
    let launchPath = selectedRoot + "/Profiles/work.default-release"
    let profileIdentity = FirefoxProfileIdentity.identifier(
      for: URL(fileURLWithPath: launchPath, isDirectory: true)
    )
    let firefox = BrowserApplication(
      id: "org.mozilla.firefox",
      family: .firefox,
      displayName: "Firefox",
      bundleIdentifier: "org.mozilla.firefox",
      applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
      executableURL: URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox"),
      isAvailable: true
    )
    let target = BrowserTarget(
      id: "org.mozilla.firefox|\(profileIdentity)|normal",
      browserID: firefox.id,
      label: "Work",
      profileIdentifier: "Work",
      profileDisplayName: "Work",
      profileIdentity: profileIdentity,
      profileLaunchPath: launchPath,
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available
    )

    try JSONConfigStore(directory: directory).save(
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [firefox], targets: [target])
    )

    let data = try Data(contentsOf: directory.appending(path: "PickViaConfig.json"))
    let document = try XCTUnwrap(String(data: data, encoding: .utf8))
    XCTAssertFalse(document.contains("/Users"))
    XCTAssertFalse(document.contains("private-user"))
    XCTAssertFalse(document.contains(selectedRoot))
    XCTAssertFalse(document.contains(launchPath))
  }

  func testStoreRefusesToPersistLegacyAbsoluteFirefoxIdentityBeforeReconciliation() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = "/Users/private-user/Library/Application Support/Firefox/Profiles/legacy"
    let firefox = BrowserApplication(
      id: "org.mozilla.firefox",
      family: .firefox,
      displayName: "Firefox",
      bundleIdentifier: "org.mozilla.firefox",
      applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
      executableURL: URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox"),
      isAvailable: true
    )
    let legacy = BrowserTarget(
      id: "org.mozilla.firefox|\(path)|normal",
      browserID: firefox.id,
      label: "Legacy",
      profileIdentifier: "Legacy",
      profileDisplayName: "Legacy",
      profileIdentity: path,
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available
    )
    let store = JSONConfigStore(directory: directory)

    XCTAssertThrowsError(
      try store.save(
        PickViaConfig(
          schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [firefox], targets: [legacy])
      ))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appending(path: "PickViaConfig.json").path
      ))
  }

  func testLegacySubstitutedPathsAreIgnoredWhenDecodingPersistedBrowser() throws {
    let data = Data(
      """
      {
        "id":"com.google.Chrome",
        "displayName":"Google Chrome",
        "bundleIdentifier":"com.google.Chrome",
        "capabilities":[
          {
            "kind":"browser",
            "family":"chromium",
            "isAvailable":true
          }
        ],
        "applicationURL":"file:///tmp/Evil.app/",
        "browserExecutableURL":"file:///tmp/payload",
        "executableURL":"file:///tmp/payload",
        "isAvailable":true
      }
      """.utf8
    )

    let browser = try JSONDecoder().decode(BrowserApplication.self, from: data)

    XCTAssertEqual(browser.applicationURL.standardizedFileURL.path, "/")
    XCTAssertNil(browser.executableURL)
  }

  func testCorruptFileIsQuarantinedAndReturnsInitialConfiguration() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appending(path: "PickViaConfig.json")
    try Data("not valid json".utf8).write(to: fileURL)
    let store = JSONConfigStore(
      directory: directory,
      now: { Date(timeIntervalSince1970: 1_700_000_000) }
    )

    XCTAssertEqual(try store.load(), .initial)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath:
          directory
          .appending(path: "PickViaConfig.json.corrupt-1700000000")
          .path
      )
    )
  }

  func testStoreRefusesPathBearingOrNoncanonicalDetectedFirefoxTargetIDs() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = "/Users/private-user/Library/Application Support/Firefox/Profiles/legacy"
    let identity = FirefoxProfileIdentity.identifier(
      for: URL(fileURLWithPath: path, isDirectory: true)
    )
    let firefox = BrowserApplication(
      id: "org.mozilla.firefox",
      family: .firefox,
      displayName: "Firefox",
      bundleIdentifier: "org.mozilla.firefox",
      applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
      executableURL: URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox"),
      isAvailable: true
    )
    let invalidIDs = [
      "org.mozilla.firefox|\(path)|normal",
      "file:///Users/private-user/legacy-target",
      "org.mozilla.firefox|wrong-opaque-value|normal",
    ]

    for (index, invalidID) in invalidIDs.enumerated() {
      let target = BrowserTarget(
        id: invalidID,
        browserID: firefox.id,
        label: "Legacy",
        profileIdentifier: "Legacy",
        profileDisplayName: "Legacy",
        profileIdentity: identity,
        mode: .normal,
        isEnabled: true,
        sortOrder: index,
        origin: .detected,
        availability: .available
      )
      let store = JSONConfigStore(directory: directory.appending(path: "case-\(index)"))

      XCTAssertThrowsError(
        try store.save(
          PickViaConfig(
            schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [firefox],
            targets: [target])
        ))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: store.directory.appending(path: "PickViaConfig.json").path
        ))
    }
  }

  func testFirefoxPersistencePolicyDecodesPercentEncodingToFixedPoint() {
    let forbidden = [
      "%252FUsers%252Fprivate-user%252Fprofile",
      "%25252FUsers%25252Fprivate-user%25252Fprofile",
      "file%253A%252F%252F%252FUsers%252Fprivate-user%252Fprofile",
      "%255CUsers%255Cprivate-user%255Cprofile",
      "%257E%252FLibrary%252FApplication%2520Support",
    ]
    for value in forbidden {
      XCTAssertTrue(
        FirefoxPersistencePolicy.isForbiddenTargetID(value),
        "Expected multiply encoded path to be forbidden: \(value)"
      )
    }

    let benign = [
      "100%25 Real",
      "Discount%2525Profile",
      "literal%zz",
      "profile%20with%20spaces",
    ]
    for value in benign {
      XCTAssertFalse(
        FirefoxPersistencePolicy.isForbiddenTargetID(value),
        "Expected benign percent text to remain allowed: \(value)"
      )
    }
  }

  func testFirefoxPersistencePolicyDecodesValidEscapesBesideMalformedPercentText() {
    let forbidden = [
      "%252FUsers%252Fprivate-user%252Fprofile%25zz",
      "%252fUsers%252fprivate-user%252fprofile%25zZ",
      "file%253a%252f%252f%252fUsers%252fprivate-user%25xy",
      "%2525255cUsers%2525255cprivate-user%2525no",
    ]
    for value in forbidden {
      XCTAssertTrue(
        FirefoxPersistencePolicy.isForbiddenTargetID(value),
        "Expected a mixed malformed value to expose its encoded path: \(value)"
      )
    }

    let benign = [
      "literal%zz",
      "literal%2G",
      "Discount%2525zz",
      "100%25 Real%zz",
      "profile%20with%20spaces%xy",
    ]
    for value in benign {
      XCTAssertFalse(
        FirefoxPersistencePolicy.isForbiddenTargetID(value),
        "Expected malformed literal percent text without path material to remain allowed: \(value)"
      )
    }
  }

  func testFirefoxPersistencePolicyFailsClosedOnlyWhenDecodeDepthOrSizeLimitIsExceeded() {
    let exactlyEightEncodedBenignValue = "%2525252525252541"
    let nineTimesEncodedBenignValue = "%252525252525252541"

    XCTAssertFalse(
      FirefoxPersistencePolicy.isForbiddenTargetID(exactlyEightEncodedBenignValue)
    )
    XCTAssertTrue(
      FirefoxPersistencePolicy.isForbiddenTargetID(nineTimesEncodedBenignValue)
    )
    XCTAssertFalse(
      FirefoxPersistencePolicy.isForbiddenTargetID(String(repeating: "a", count: 65_536))
    )
    XCTAssertTrue(
      FirefoxPersistencePolicy.isForbiddenTargetID(String(repeating: "a", count: 65_537))
    )
  }

  func testStoreRefusesMultiplyEncodedFirefoxPathsAcrossPersistentFields() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firefox = BrowserApplication(
      id: "org.mozilla.firefox",
      family: .firefox,
      displayName: "Firefox",
      bundleIdentifier: "org.mozilla.firefox",
      applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
      executableURL: URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox"),
      isAvailable: true
    )
    let identity = FirefoxProfileIdentity.identifier(
      for: URL(fileURLWithPath: "/Users/private-user/Firefox/Profiles/work")
    )
    let forbiddenPath =
      "%252fUsers%252fprivate-user%252fFirefox%252fProfiles%252fwork%25zz"
    let targets = [
      BrowserTarget(
        id: forbiddenPath,
        browserID: firefox.id,
        label: "Encoded ID",
        profileIdentifier: nil,
        profileDisplayName: nil,
        profileIdentity: nil,
        mode: .normal,
        isEnabled: true,
        sortOrder: 0,
        origin: .manual,
        availability: .available
      ),
      BrowserTarget(
        id: "manual-encoded-identifier",
        browserID: firefox.id,
        label: "Encoded Identifier",
        profileIdentifier: forbiddenPath,
        profileDisplayName: "Work",
        profileIdentity: identity,
        mode: .normal,
        isEnabled: true,
        sortOrder: 0,
        origin: .manual,
        availability: .available
      ),
      BrowserTarget(
        id: "manual-encoded-display",
        browserID: firefox.id,
        label: "Encoded Display",
        profileIdentifier: "Work",
        profileDisplayName: forbiddenPath,
        profileIdentity: identity,
        mode: .normal,
        isEnabled: true,
        sortOrder: 0,
        origin: .manual,
        availability: .available
      ),
      BrowserTarget(
        id: "manual-encoded-identity",
        browserID: firefox.id,
        label: "Encoded Identity",
        profileIdentifier: "Work",
        profileDisplayName: "Work",
        profileIdentity: forbiddenPath,
        mode: .normal,
        isEnabled: true,
        sortOrder: 0,
        origin: .manual,
        availability: .available
      ),
    ]

    for (index, target) in targets.enumerated() {
      let store = JSONConfigStore(directory: directory.appending(path: "case-\(index)"))
      XCTAssertThrowsError(
        try store.save(
          PickViaConfig(
            schemaVersion: PickViaConfig.currentSchemaVersion,
            browsers: [firefox],
            targets: [target]
          )
        )
      ) { error in
        XCTAssertEqual(error as? ConfigDocumentError, .invalidTarget)
      }
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: store.directory.appending(path: "PickViaConfig.json").path
        )
      )
    }
  }

  func testStoreAcceptsOpaqueFirefoxIdentityWithManualUUIDTargetID() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = "/Users/private-user/Library/Application Support/Firefox/Profiles/manual"
    let identity = FirefoxProfileIdentity.identifier(
      for: URL(fileURLWithPath: path, isDirectory: true)
    )
    let firefox = BrowserApplication(
      id: "org.mozilla.firefox",
      family: .firefox,
      displayName: "Firefox",
      bundleIdentifier: "org.mozilla.firefox",
      applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
      executableURL: URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox"),
      isAvailable: true
    )
    let manual = BrowserTarget(
      id: "774bb7ed-d61c-4be7-89f1-6c16daf287be",
      browserID: firefox.id,
      label: "Pinned",
      profileIdentifier: "Work",
      profileDisplayName: "Work",
      profileIdentity: identity,
      profileLaunchPath: path,
      mode: .private,
      isEnabled: true,
      sortOrder: 0,
      origin: .manual,
      availability: .available
    )
    let store = JSONConfigStore(directory: directory)

    try store.save(
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [firefox], targets: [manual])
    )

    let document = try XCTUnwrap(
      String(
        data: Data(contentsOf: directory.appending(path: "PickViaConfig.json")),
        encoding: .utf8
      )
    )
    XCTAssertTrue(document.contains(manual.id))
    XCTAssertFalse(document.contains(path))
  }

  func testStoreAcceptsOnlyUnavailablePathFreeNameOnlyDetectedFirefoxMigration() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let firefox = BrowserApplication(
      id: "org.mozilla.firefox",
      family: .firefox,
      displayName: "Firefox",
      bundleIdentifier: "org.mozilla.firefox",
      applicationURL: URL(fileURLWithPath: "/Applications/Firefox.app"),
      executableURL: URL(fileURLWithPath: "/Applications/Firefox.app/Contents/MacOS/firefox"),
      isAvailable: true
    )
    func legacy(
      profileName: String,
      availability: BrowserTargetAvailability
    ) -> BrowserTarget {
      BrowserTarget(
        id: BrowserCatalog.targetID(
          bundleIdentifier: firefox.id,
          profileIdentifier: profileName,
          mode: .normal
        ),
        browserID: firefox.id,
        label: "Legacy",
        profileIdentifier: profileName,
        profileDisplayName: profileName,
        profileIdentity: nil,
        mode: .normal,
        isEnabled: true,
        sortOrder: 0,
        origin: .detected,
        availability: availability
      )
    }

    let migratable = legacy(profileName: "Work Profile", availability: .unavailable)
    try JSONConfigStore(directory: directory.appending(path: "valid")).save(
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [firefox],
        targets: [migratable])
    )

    let invalid = [
      legacy(profileName: "Work Profile", availability: .available),
      legacy(profileName: "%2FUsers%2Fprivate-user", availability: .unavailable),
      legacy(profileName: "~%2FLibrary", availability: .unavailable),
      legacy(profileName: "file:%2F%2FUsers%2Fprivate-user", availability: .unavailable),
    ]
    for (index, target) in invalid.enumerated() {
      let caseDirectory = directory.appending(path: "invalid-\(index)")
      XCTAssertThrowsError(
        try JSONConfigStore(directory: caseDirectory).save(
          PickViaConfig(
            schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [firefox],
            targets: [target])
        ))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: caseDirectory.appending(path: "PickViaConfig.json").path
        ))
    }
  }

  func testReadFailureIsPropagatedWithoutQuarantiningConfiguration() {
    let fileSystem = ReadFailingFileSystem()
    let store = JSONConfigStore(
      directory: URL(fileURLWithPath: "/virtual/application-support"),
      fileSystem: fileSystem
    )

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? ConfigLoadFailure, .readFailed)
    }
    XCTAssertEqual(fileSystem.moveCallCount, 0)
  }

  func testSavingOverExistingFileReplacesConfigurationAndLeavesNoTemporaryFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(directory: directory)
    let first = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion, browsers: [], targets: [])
    let second = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: [validChrome],
      targets: [validTarget]
    )

    try store.save(first)
    try store.save(second)

    let loaded = try store.load()
    XCTAssertEqual(loaded.targets, second.targets)
    XCTAssertEqual(loaded.browsers.map(\.id), second.browsers.map(\.id))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appending(path: "PickViaConfig.json.tmp").path
      )
    )
  }

  func testSaveLeavesNoTemporaryFile() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(directory: directory)

    try store.save(.initial)

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: directory.appending(path: "PickViaConfig.json.tmp").path
      )
    )
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "PickViaCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

private let validChrome = BrowserApplication(
  id: "com.google.Chrome",
  family: .chromium,
  displayName: "Google Chrome",
  bundleIdentifier: "com.google.Chrome",
  applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
  executableURL: URL(
    fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
  isAvailable: true
)

private func descriptorApplication(_ descriptor: BrowserDescriptor) -> BrowserApplication {
  BrowserApplication(
    id: descriptor.bundleIdentifier,
    family: descriptor.family,
    displayName: descriptor.displayName,
    bundleIdentifier: descriptor.bundleIdentifier,
    applicationURL: URL(fileURLWithPath: "/Applications/\(descriptor.displayName).app"),
    executableURL: nil,
    isAvailable: true
  )
}

private let newChannelApplications: [BrowserApplication] = [
  channelApplication(
    id: "com.apple.SafariTechnologyPreview",
    family: .safari,
    displayName: "Safari Technology Preview",
    executableName: nil
  ),
  channelApplication(
    id: "com.google.Chrome.dev",
    family: .chromium,
    displayName: "Google Chrome Dev",
    executableName: "Google Chrome Dev"
  ),
  channelApplication(
    id: "com.google.Chrome.canary",
    family: .chromium,
    displayName: "Google Chrome Canary",
    executableName: "Google Chrome Canary"
  ),
  channelApplication(
    id: "com.microsoft.edgemac.Beta",
    family: .chromium,
    displayName: "Microsoft Edge Beta",
    executableName: "Microsoft Edge Beta"
  ),
  channelApplication(
    id: "com.microsoft.edgemac.Dev",
    family: .chromium,
    displayName: "Microsoft Edge Dev",
    executableName: "Microsoft Edge Dev"
  ),
  channelApplication(
    id: "com.microsoft.edgemac.Canary",
    family: .chromium,
    displayName: "Microsoft Edge Canary",
    executableName: "Microsoft Edge Canary"
  ),
  channelApplication(
    id: "com.brave.Browser.beta",
    family: .chromium,
    displayName: "Brave Beta",
    applicationName: "Brave Browser Beta",
    executableName: "Brave Browser Beta"
  ),
  channelApplication(
    id: "com.brave.Browser.nightly",
    family: .chromium,
    displayName: "Brave Nightly",
    applicationName: "Brave Browser Nightly",
    executableName: "Brave Browser Nightly"
  ),
  channelApplication(
    id: "com.vivaldi.Vivaldi.snapshot",
    family: .chromium,
    displayName: "Vivaldi Snapshot",
    executableName: "Vivaldi Snapshot"
  ),
  channelApplication(
    id: "org.mozilla.firefoxdeveloperedition",
    family: .firefox,
    displayName: "Firefox Developer Edition",
    executableName: "firefox"
  ),
  channelApplication(
    id: "org.mozilla.nightly",
    family: .firefox,
    displayName: "Firefox Nightly",
    executableName: "firefox"
  ),
]

private func channelApplication(
  id: String,
  family: BrowserFamily,
  displayName: String,
  applicationName: String? = nil,
  executableName: String?
) -> BrowserApplication {
  let applicationURL = URL(
    fileURLWithPath: "/Applications/\(applicationName ?? displayName).app",
    isDirectory: true
  )
  return BrowserApplication(
    id: id,
    family: family,
    displayName: displayName,
    bundleIdentifier: id,
    applicationURL: applicationURL,
    executableURL: executableName.map {
      applicationURL.appending(path: "Contents/MacOS/\($0)")
    },
    isAvailable: true
  )
}

private let validTarget = BrowserTarget(
  id: "com.google.Chrome|Default|normal",
  browserID: validChrome.id,
  label: "Personal",
  profileIdentifier: "Default",
  profileDisplayName: "Personal",
  mode: .normal,
  isEnabled: true,
  sortOrder: 0,
  origin: .detected,
  availability: .available
)

private func makeTarget(
  id: String,
  profile: String?,
  mode: BrowserMode,
  enabled: Bool,
  origin: BrowserTargetOrigin = .detected
) -> BrowserTarget {
  let baseLabel = profile ?? validChrome.displayName
  return BrowserTarget(
    id: id,
    browserID: validChrome.id,
    label: mode == .private ? "\(baseLabel) Private" : baseLabel,
    profileIdentifier: profile,
    profileDisplayName: profile,
    profileIdentity: profile,
    mode: mode,
    isEnabled: enabled,
    sortOrder: 0,
    origin: origin,
    availability: .available
  )
}

private let validSafari = BrowserApplication(
  id: "com.apple.Safari",
  family: .safari,
  displayName: "Safari",
  bundleIdentifier: "com.apple.Safari",
  applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"),
  executableURL: nil,
  isAvailable: true
)

private let validSafariTargetWithMetadata = BrowserTarget(
  id: "com.apple.Safari||normal",
  browserID: validSafari.id,
  label: "Safari",
  profileIdentifier: nil,
  profileDisplayName: "Unexpected",
  profileIdentity: "/unexpected/profile",
  mode: .normal,
  isEnabled: true,
  sortOrder: 0,
  origin: .detected,
  availability: .available
)

private func copyTarget(
  _ target: BrowserTarget,
  id: String? = nil,
  browserID: String? = nil,
  label: String? = nil,
  profileIdentity: String? = nil
) -> BrowserTarget {
  BrowserTarget(
    id: id ?? target.id,
    browserID: browserID ?? target.browserID,
    label: label ?? target.label,
    profileIdentifier: target.profileIdentifier,
    profileDisplayName: target.profileDisplayName,
    profileIdentity: profileIdentity ?? target.profileIdentity,
    mode: target.mode,
    isEnabled: target.isEnabled,
    sortOrder: target.sortOrder,
    origin: target.origin,
    availability: target.availability
  )
}

private enum FileSystemTestError: Error, Equatable {
  case readFailed
}

private final class ReadFailingFileSystem: FileSystem, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedMoveCallCount = 0

  var moveCallCount: Int {
    lock.withLock { recordedMoveCallCount }
  }

  func createDirectory(at url: URL) throws {}

  func fileExists(at url: URL) -> Bool {
    true
  }

  func read(from url: URL) throws -> Data {
    throw FileSystemTestError.readFailed
  }

  func writeAtomically(_ data: Data, to url: URL) throws {
    preconditionFailure("Unexpected write")
  }

  func moveItem(at source: URL, to destination: URL) throws {
    lock.withLock {
      recordedMoveCallCount += 1
    }
  }

  func replaceItem(at destination: URL, with source: URL) throws {
    preconditionFailure("Unexpected replacement")
  }
}
