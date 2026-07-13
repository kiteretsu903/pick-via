import Foundation
import XCTest

@testable import PickVia
@testable import PickViaCore

@MainActor
final class AppModelTests: XCTestCase {
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

  func testRescanReconcilesAndPersistsConfiguration() throws {
    let store = ConfigStoreStub(config: Fixtures.config)
    let reconciled = PickViaConfig(
      schemaVersion: 1,
      browsers: Fixtures.config.browsers,
      targets: [Fixtures.target(label: "Reconciled")]
    )
    let catalog = BrowserCatalogStub(discovered: [], reconciled: reconciled)
    let model = makeModel(store: store, catalog: catalog)
    try model.load()

    try model.rescan()

    XCTAssertEqual(model.config, reconciled)
    XCTAssertEqual(catalog.reconcileInputs, [Fixtures.config])
    XCTAssertEqual(store.saved, [reconciled])
  }

  func testThirdOnboardingStepIsDisabledWithoutValidEnabledTarget() throws {
    let unavailable = Fixtures.target(
      isEnabled: true,
      availability: .unavailable
    )
    let config = PickViaConfig(
      schemaVersion: 1,
      browsers: Fixtures.config.browsers,
      targets: [unavailable]
    )
    let model = makeModel(store: ConfigStoreStub(config: config))

    try model.load()

    XCTAssertFalse(model.canRequestDefaultBrowser)
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
    let incomplete = DefaultBrowserStatus(http: .notDefault, https: .notDefault)
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
    let incomplete = DefaultBrowserStatus(http: .notDefault, https: .notDefault)
    let partial = DefaultBrowserStatus(http: .isDefault, https: .notDefault)
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

  func testDualSchemeDefaultStatusCompletesOnboarding() async throws {
    let incomplete = DefaultBrowserStatus(http: .notDefault, https: .notDefault)
    let complete = DefaultBrowserStatus(http: .isDefault, https: .isDefault)
    let preferences = PreferencesStub(integers: ["onboardingStep": 3])
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
    XCTAssertTrue(model.isOnboardingComplete)
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(preferences.setIntegers["onboardingStep"], 4)
  }

  func testPersistedCompletionIsClampedWhenDefaultStatusIsIncomplete() throws {
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
    XCTAssertNotNil(model.errorMessage)

    model.accept(url: URL(string: "https://example.com/path")!)

    XCTAssertEqual(routing.acceptedURLs, [URL(string: "https://example.com/path")!])
    XCTAssertNil(model.errorMessage)
  }

  func testChooserPreviewNeverUsesAcceptedURLPath() throws {
    let routing = RoutingSpy()
    let model = makeModel(routing: routing)
    try model.load()

    model.previewChooser()

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
    let config = PickViaConfig(schemaVersion: 1, browsers: [unsupported], targets: [])
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
      schemaVersion: 1,
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
      schemaVersion: 1,
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
      schemaVersion: 1,
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
    let config = PickViaConfig(schemaVersion: 1, browsers: [Fixtures.chrome], targets: [manualOnly])
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
    store: ConfigStoreStub = ConfigStoreStub(config: .initial),
    catalog: BrowserCatalogStub = BrowserCatalogStub(),
    preferences: PreferencesStub = PreferencesStub(),
    defaultBrowser: DefaultBrowserSpy = DefaultBrowserSpy(),
    loginItem: LoginItemStub = LoginItemStub(),
    routing: RoutingSpy = RoutingSpy()
  ) -> AppModel {
    AppModel(
      configStore: store,
      browserCatalog: catalog,
      preferences: preferences,
      defaultBrowser: defaultBrowser,
      loginItem: loginItem,
      routing: routing
    )
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
    schemaVersion: 1,
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

  static let editableConfig = PickViaConfig(
    schemaVersion: 1,
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
    schemaVersion: 1,
    browsers: [chrome],
    targets: editableConfig.targets + [
      BrowserTarget(
        id: "personal", browserID: chrome.id, label: "Personal", profileIdentifier: "Profile 2",
        profileDisplayName: "Personal", mode: .normal, isEnabled: true, sortOrder: 21,
        origin: .detected, availability: .available)
    ]
  )

  static let safariConfig = PickViaConfig(
    schemaVersion: 1,
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
}

private final class ConfigStoreStub: ConfigStoring, @unchecked Sendable {
  var config: PickViaConfig
  private(set) var loadCallCount = 0
  private(set) var saved: [PickViaConfig] = []
  let saveError: Error?

  init(config: PickViaConfig, saveError: Error? = nil) {
    self.config = config
    self.saveError = saveError
  }
  func load() throws -> PickViaConfig {
    loadCallCount += 1
    return config
  }
  func save(_ config: PickViaConfig) throws {
    if let saveError { throw saveError }
    saved.append(config)
  }
}

private final class BrowserCatalogStub: BrowserDiscovering, @unchecked Sendable {
  var discovered: [DiscoveredBrowser]
  var reconciled: PickViaConfig
  private(set) var reconcileInputs: [PickViaConfig] = []
  private let reconciler: ((PickViaConfig) -> PickViaConfig)?

  init(
    discovered: [DiscoveredBrowser] = [],
    reconciled: PickViaConfig = .initial,
    reconciler: ((PickViaConfig) -> PickViaConfig)? = nil
  ) {
    self.discovered = discovered
    self.reconciled = reconciled
    self.reconciler = reconciler
  }

  func scan() throws -> [DiscoveredBrowser] { discovered }
  func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig {
    reconcileInputs.append(config)
    return reconciler?(config) ?? reconciled
  }
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
private final class DefaultBrowserSpy: DefaultBrowserServicing {
  var statuses: [DefaultBrowserStatus]
  var requestError: Error?
  private(set) var statusCallCount = 0
  private(set) var requestedSchemes: [String] = []

  init(
    status: DefaultBrowserStatus = .unknown,
    requestError: Error? = nil
  ) {
    statuses = [status]
    self.requestError = requestError
  }

  init(statuses: [DefaultBrowserStatus], requestError: Error? = nil) {
    precondition(!statuses.isEmpty)
    self.statuses = statuses
    self.requestError = requestError
  }

  func status() -> DefaultBrowserStatus {
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

  func accept(_ url: URL) { acceptedURLs.append(url) }
  func preview(_ url: URL) { previewedURLs.append(url) }
}
