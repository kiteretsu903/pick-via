import Foundation
import Observation
import PickViaCore

@MainActor
@Observable
public final class AppModel {
    public private(set) var config: PickViaConfig = .initial
    public private(set) var defaultStatus: DefaultBrowserStatus = .unknown
    public private(set) var launchesAtLogin = false
    public private(set) var errorMessage: String?

    public var showsURLInChooser: Bool {
        didSet {
            guard isLoaded else { return }
            preferences.set(showsURLInChooser, forKey: PreferenceKey.showsURLInChooser)
        }
    }

    public var onboardingStep: Int {
        didSet {
            guard isLoaded else { return }
            preferences.set(onboardingStep, forKey: PreferenceKey.onboardingStep)
        }
    }

    public var browsers: [BrowserApplication] { config.browsers }
    public var targets: [BrowserTarget] { config.targets }

    public var canRequestDefaultBrowser: Bool {
        config.targets.contains { target in
            guard
                target.isEnabled,
                target.availability == .available,
                let browser = config.browsers.first(where: { $0.id == target.browserID })
            else { return false }
            return browser.isAvailable
        }
    }

    private let configStore: any ConfigStoring
    private let browserCatalog: any BrowserDiscovering
    private let preferences: any PreferencesStoring
    private let defaultBrowser: any DefaultBrowserServicing
    private let loginItem: any LoginItemServicing
    private let routing: any AppRouting
    private var isLoaded = false

    public init(
        configStore: any ConfigStoring,
        browserCatalog: any BrowserDiscovering,
        preferences: any PreferencesStoring,
        defaultBrowser: any DefaultBrowserServicing,
        loginItem: any LoginItemServicing,
        routing: any AppRouting
    ) {
        self.configStore = configStore
        self.browserCatalog = browserCatalog
        self.preferences = preferences
        self.defaultBrowser = defaultBrowser
        self.loginItem = loginItem
        self.routing = routing
        showsURLInChooser = true
        onboardingStep = 1
    }

    public func load() throws {
        guard !isLoaded else { return }

        config = try configStore.load()
        showsURLInChooser = preferences.bool(forKey: PreferenceKey.showsURLInChooser) ?? true
        onboardingStep = preferences.integer(forKey: PreferenceKey.onboardingStep) ?? 1
        launchesAtLogin = loginItem.isEnabled
        defaultStatus = defaultBrowser.status()
        isLoaded = true
    }

    public func rescan() throws {
        let discovered = try browserCatalog.scan()
        let reconciled = browserCatalog.reconcile(discovered: discovered, with: config)
        try configStore.save(reconciled)
        config = reconciled
        errorMessage = nil
    }

    public func accept(url: URL) {
        do {
            let validated = try URLValidator.validate(url)
            routing.accept(validated)
            errorMessage = nil
        } catch {
            errorMessage = "Only valid HTTP and HTTPS URLs can be opened."
        }
    }

    public func previewChooser() {
        routing.preview(URL(string: "https://pickvia.invalid/chooser-preview")!)
    }

    public func requestDefaultBrowser() async {
        guard canRequestDefaultBrowser else { return }

        errorMessage = nil
        do {
            try await defaultBrowser.requestDefault(for: ["http", "https"])
        } catch {
            errorMessage = "PickVia was not made the default browser. You can try again."
        }
        defaultStatus = defaultBrowser.status()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        let previous = launchesAtLogin
        launchesAtLogin = enabled
        errorMessage = nil

        do {
            try loginItem.setEnabled(enabled)
        } catch {
            launchesAtLogin = previous
            errorMessage = "The launch-at-login setting could not be changed."
        }
    }
}

private enum PreferenceKey {
    static let showsURLInChooser = "showsURLInChooser"
    static let onboardingStep = "onboardingStep"
}
