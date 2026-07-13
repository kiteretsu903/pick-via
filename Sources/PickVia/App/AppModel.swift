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

    public private(set) var onboardingStep: Int {
        didSet {
            guard isLoaded else { return }
            preferences.set(onboardingStep, forKey: PreferenceKey.onboardingStep)
        }
    }

    public var browsers: [BrowserApplication] { config.browsers }
    public var targets: [BrowserTarget] { config.targets }
    public var isOnboardingComplete: Bool {
        onboardingStep == Onboarding.completedStep && hasConfirmedDefaultStatus
    }

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
        launchesAtLogin = loginItem.isEnabled
        defaultStatus = defaultBrowser.status()
        let persistedStep = preferences.integer(forKey: PreferenceKey.onboardingStep) ?? Onboarding.firstStep
        onboardingStep = normalizedOnboardingStep(persistedStep)
        if onboardingStep != persistedStep {
            preferences.set(onboardingStep, forKey: PreferenceKey.onboardingStep)
        }
        isLoaded = true
    }

    public func advanceOnboarding() {
        switch onboardingStep {
        case Onboarding.firstStep:
            onboardingStep = 2
        case 2 where canRequestDefaultBrowser:
            onboardingStep = Onboarding.defaultBrowserStep
        default:
            break
        }
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

        // Status is authoritative; refresh it even when the consent API throws.
        _ = try? await defaultBrowser.requestDefault(for: ["http", "https"])
        defaultStatus = defaultBrowser.status()

        if hasConfirmedDefaultStatus {
            onboardingStep = Onboarding.completedStep
            errorMessage = nil
        } else {
            if onboardingStep >= Onboarding.completedStep {
                onboardingStep = Onboarding.defaultBrowserStep
            }
            errorMessage = "PickVia was not made the default browser for HTTP and HTTPS. You can try again."
        }
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

    private var hasConfirmedDefaultStatus: Bool {
        defaultStatus.http == .isDefault && defaultStatus.https == .isDefault
    }

    private func normalizedOnboardingStep(_ persistedStep: Int) -> Int {
        let bounded = min(
            max(persistedStep, Onboarding.firstStep),
            Onboarding.completedStep
        )
        if bounded == Onboarding.completedStep && !hasConfirmedDefaultStatus {
            return Onboarding.defaultBrowserStep
        }
        return bounded
    }
}

private enum PreferenceKey {
    static let showsURLInChooser = "showsURLInChooser"
    static let onboardingStep = "onboardingStep"
}

private enum Onboarding {
    static let firstStep = 1
    static let defaultBrowserStep = 3
    static let completedStep = 4
}
