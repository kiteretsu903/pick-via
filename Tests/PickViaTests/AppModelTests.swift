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
}

private final class ConfigStoreStub: ConfigStoring, @unchecked Sendable {
    var config: PickViaConfig
    private(set) var loadCallCount = 0
    private(set) var saved: [PickViaConfig] = []

    init(config: PickViaConfig) { self.config = config }
    func load() throws -> PickViaConfig { loadCallCount += 1; return config }
    func save(_ config: PickViaConfig) throws { saved.append(config) }
}

private final class BrowserCatalogStub: BrowserDiscovering, @unchecked Sendable {
    var discovered: [DiscoveredBrowser]
    var reconciled: PickViaConfig
    private(set) var reconcileInputs: [PickViaConfig] = []

    init(discovered: [DiscoveredBrowser] = [], reconciled: PickViaConfig = .initial) {
        self.discovered = discovered
        self.reconciled = reconciled
    }

    func scan() throws -> [DiscoveredBrowser] { discovered }
    func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig {
        reconcileInputs.append(config)
        return reconciled
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
    func set(_ value: Bool, forKey key: String) { setBooleans[key] = value; booleans[key] = value }
    func set(_ value: Int, forKey key: String) { setIntegers[key] = value; integers[key] = value }
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
