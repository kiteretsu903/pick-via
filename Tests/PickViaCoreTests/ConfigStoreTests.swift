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
        schemaVersion: 1,
        browsers: [validChrome, validChrome],
        targets: []
      ),
      PickViaConfig(
        schemaVersion: 1,
        browsers: [validChrome],
        targets: [copyTarget(validTarget, id: "blank-label", label: "  ")]
      ),
      PickViaConfig(
        schemaVersion: 1,
        browsers: [validChrome],
        targets: [validTarget, validTarget]
      ),
      PickViaConfig(
        schemaVersion: 1,
        browsers: [validChrome],
        targets: [copyTarget(validTarget, id: "mismatch", browserID: "missing-browser")]
      ),
      PickViaConfig(
        schemaVersion: 1,
        browsers: [validChrome],
        targets: [copyTarget(validTarget, id: "bad-profile", profileIdentity: "  ")]
      ),
      PickViaConfig(
        schemaVersion: 1,
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
    let expected = PickViaConfig(schemaVersion: 1, browsers: [validChrome], targets: [target])

    try store.save(expected)

    let loaded = try store.load()
    XCTAssertEqual(loaded.schemaVersion, expected.schemaVersion)
    XCTAssertEqual(loaded.targets, expected.targets)
    XCTAssertEqual(loaded.browsers.map(\.id), expected.browsers.map(\.id))
    XCTAssertEqual(loaded.browsers.map(\.displayName), expected.browsers.map(\.displayName))
  }

  func testSavedDocumentDoesNotPersistApplicationOrExecutablePaths() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONConfigStore(directory: directory)

    try store.save(
      PickViaConfig(schemaVersion: 1, browsers: [validChrome], targets: [validTarget])
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
      PickViaConfig(schemaVersion: 1, browsers: [firefox], targets: [target])
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
        PickViaConfig(schemaVersion: 1, browsers: [firefox], targets: [legacy])
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
        "family":"chromium",
        "displayName":"Google Chrome",
        "bundleIdentifier":"com.google.Chrome",
        "applicationURL":"file:///tmp/Evil.app/",
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
          PickViaConfig(schemaVersion: 1, browsers: [firefox], targets: [target])
        ))
      XCTAssertFalse(
        FileManager.default.fileExists(
          atPath: store.directory.appending(path: "PickViaConfig.json").path
        ))
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
      PickViaConfig(schemaVersion: 1, browsers: [firefox], targets: [manual])
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
      PickViaConfig(schemaVersion: 1, browsers: [firefox], targets: [migratable])
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
          PickViaConfig(schemaVersion: 1, browsers: [firefox], targets: [target])
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
    let first = PickViaConfig(schemaVersion: 1, browsers: [], targets: [])
    let second = PickViaConfig(
      schemaVersion: 1,
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
