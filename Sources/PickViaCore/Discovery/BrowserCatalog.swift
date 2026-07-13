import AppKit
import Foundation

public struct BrowserDescriptor: Sendable {
    public let bundleIdentifier: String
    public let family: BrowserFamily
    public let displayName: String
    public let profileRoot: String?
    public let executableRelativePath: String?

    public init(
        bundleIdentifier: String,
        family: BrowserFamily,
        displayName: String,
        profileRoot: String?,
        executableRelativePath: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.family = family
        self.displayName = displayName
        self.profileRoot = profileRoot
        self.executableRelativePath = executableRelativePath
    }

    public static let supported: [BrowserDescriptor] = [
        BrowserDescriptor(
            bundleIdentifier: "com.apple.Safari",
            family: .safari,
            displayName: "Safari",
            profileRoot: nil,
            executableRelativePath: nil
        ),
        BrowserDescriptor(
            bundleIdentifier: "com.google.Chrome",
            family: .chromium,
            displayName: "Google Chrome",
            profileRoot: "Library/Application Support/Google/Chrome",
            executableRelativePath: "Contents/MacOS/Google Chrome"
        ),
        BrowserDescriptor(
            bundleIdentifier: "org.chromium.Chromium",
            family: .chromium,
            displayName: "Chromium",
            profileRoot: "Library/Application Support/Chromium",
            executableRelativePath: "Contents/MacOS/Chromium"
        ),
        BrowserDescriptor(
            bundleIdentifier: "com.microsoft.edgemac",
            family: .chromium,
            displayName: "Microsoft Edge",
            profileRoot: "Library/Application Support/Microsoft Edge",
            executableRelativePath: "Contents/MacOS/Microsoft Edge"
        ),
        BrowserDescriptor(
            bundleIdentifier: "com.brave.Browser",
            family: .chromium,
            displayName: "Brave Browser",
            profileRoot: "Library/Application Support/BraveSoftware/Brave-Browser",
            executableRelativePath: "Contents/MacOS/Brave Browser"
        ),
        BrowserDescriptor(
            bundleIdentifier: "com.vivaldi.Vivaldi",
            family: .chromium,
            displayName: "Vivaldi",
            profileRoot: "Library/Application Support/Vivaldi",
            executableRelativePath: "Contents/MacOS/Vivaldi"
        ),
        BrowserDescriptor(
            bundleIdentifier: "org.mozilla.firefox",
            family: .firefox,
            displayName: "Firefox",
            profileRoot: "Library/Application Support/Firefox",
            executableRelativePath: "Contents/MacOS/firefox"
        ),
    ]
}

public struct DiscoveredBrowser: Equatable, Sendable {
    public let application: BrowserApplication
    public let profiles: [DiscoveredProfile]

    public init(application: BrowserApplication, profiles: [DiscoveredProfile]) {
        self.application = application
        self.profiles = profiles
    }
}

public protocol ApplicationLocating: Sendable {
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
}

public struct WorkspaceApplicationLocator: ApplicationLocating {
    public init() {}

    public func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

public protocol BrowserDiscovering: Sendable {
    func scan() throws -> [DiscoveredBrowser]
    func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig
}

public struct BrowserCatalog: BrowserDiscovering, Sendable {
    private let descriptors: [BrowserDescriptor]
    private let applicationLocator: any ApplicationLocating
    private let fileSystem: any FileSystem
    private let homeDirectory: URL

    public init(
        descriptors: [BrowserDescriptor] = BrowserDescriptor.supported,
        applicationLocator: any ApplicationLocating = WorkspaceApplicationLocator(),
        fileSystem: any FileSystem = FoundationFileSystem(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.descriptors = descriptors
        self.applicationLocator = applicationLocator
        self.fileSystem = fileSystem
        self.homeDirectory = homeDirectory
    }

    public func scan() throws -> [DiscoveredBrowser] {
        try descriptors.compactMap { descriptor in
            guard let applicationURL = applicationLocator.applicationURL(
                forBundleIdentifier: descriptor.bundleIdentifier
            ) else {
                return nil
            }

            let executableURL = descriptor.executableRelativePath.map {
                applicationURL.appending(path: $0)
            }
            let application = BrowserApplication(
                id: descriptor.bundleIdentifier,
                family: descriptor.family,
                displayName: descriptor.displayName,
                bundleIdentifier: descriptor.bundleIdentifier,
                applicationURL: applicationURL,
                executableURL: executableURL,
                isAvailable: true
            )
            let profiles = try readProfiles(for: descriptor)
            return DiscoveredBrowser(application: application, profiles: profiles)
        }
    }

    public func reconcile(
        discovered: [DiscoveredBrowser],
        with config: PickViaConfig
    ) -> PickViaConfig {
        Self.reconcile(discovered: discovered, with: config)
    }

    public static func reconcile(
        discovered: [DiscoveredBrowser],
        with config: PickViaConfig
    ) -> PickViaConfig {
        let discoveredApplications = discovered.map(\.application)
        let discoveredApplicationIDs = Set(discoveredApplications.map(\.id))
        let missingApplications = config.browsers
            .filter { !discoveredApplicationIDs.contains($0.id) }
            .map { application in
                BrowserApplication(
                    id: application.id,
                    family: application.family,
                    displayName: application.displayName,
                    bundleIdentifier: application.bundleIdentifier,
                    applicationURL: application.applicationURL,
                    executableURL: application.executableURL,
                    isAvailable: false
                )
            }
        let browsers = discoveredApplications + missingApplications

        let existingByID = Dictionary(config.targets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var nextSortOrder = (config.targets.map(\.sortOrder).max() ?? -1) + 1
        var reconciled: [BrowserTarget] = []

        for browser in discovered {
            let candidates = targetCandidates(for: browser)
            for candidate in candidates {
                if let existing = existingByID[candidate.id] {
                    reconciled.append(merging(candidate, preserving: existing))
                } else {
                    reconciled.append(BrowserTarget(
                        id: candidate.id,
                        browserID: candidate.browserID,
                        label: candidate.label,
                        profileIdentifier: candidate.profileIdentifier,
                        profileDisplayName: candidate.profileDisplayName,
                        mode: candidate.mode,
                        isEnabled: candidate.isEnabled,
                        sortOrder: nextSortOrder,
                        origin: candidate.origin,
                        availability: candidate.availability,
                        validationError: nil
                    ))
                    nextSortOrder += 1
                }
            }
        }

        let reconciledIDs = Set(reconciled.map(\.id))
        reconciled.append(contentsOf: config.targets
            .filter { !reconciledIDs.contains($0.id) }
            .map { target in
                BrowserTarget(
                    id: target.id,
                    browserID: target.browserID,
                    label: target.label,
                    profileIdentifier: target.profileIdentifier,
                    profileDisplayName: target.profileDisplayName,
                    mode: target.mode,
                    isEnabled: target.isEnabled,
                    sortOrder: target.sortOrder,
                    origin: target.origin,
                    availability: .unavailable,
                    validationError: target.validationError
                )
            })

        reconciled.sort {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.id < $1.id
        }
        return PickViaConfig(
            schemaVersion: config.schemaVersion,
            browsers: browsers,
            targets: reconciled
        )
    }

    public static func targetID(
        bundleIdentifier: String,
        profileIdentifier: String?,
        mode: BrowserMode
    ) -> String {
        [bundleIdentifier, profileIdentifier ?? "", mode.rawValue]
            .joined(separator: "|")
    }

    private func readProfiles(for descriptor: BrowserDescriptor) throws -> [DiscoveredProfile] {
        guard let profileRoot = descriptor.profileRoot else { return [] }
        let rootURL = homeDirectory.appending(path: profileRoot, directoryHint: .isDirectory)
        let metadataURL: URL
        switch descriptor.family {
        case .safari:
            return []
        case .chromium:
            metadataURL = rootURL.appending(path: "Local State")
        case .firefox:
            metadataURL = rootURL.appending(path: "profiles.ini")
        }
        guard fileSystem.fileExists(at: metadataURL) else { return [] }
        let data = try fileSystem.read(from: metadataURL)
        switch descriptor.family {
        case .safari:
            return []
        case .chromium:
            return try ChromiumProfileParser.parse(data: data)
        case .firefox:
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return try FirefoxProfileParser.parse(text: text, baseDirectory: rootURL)
        }
    }

    private static func targetCandidates(for browser: DiscoveredBrowser) -> [BrowserTarget] {
        if browser.application.family == .safari {
            return [candidate(
                browser: browser.application,
                profile: nil,
                mode: .normal
            )]
        }
        return browser.profiles.flatMap { profile in
            [
                candidate(browser: browser.application, profile: profile, mode: .normal),
                candidate(browser: browser.application, profile: profile, mode: .private),
            ]
        }
    }

    private static func candidate(
        browser: BrowserApplication,
        profile: DiscoveredProfile?,
        mode: BrowserMode
    ) -> BrowserTarget {
        let baseLabel = profile?.displayName ?? browser.displayName
        let label = mode == .private ? "\(baseLabel) Private" : baseLabel
        return BrowserTarget(
            id: targetID(
                bundleIdentifier: browser.bundleIdentifier,
                profileIdentifier: profile?.identifier,
                mode: mode
            ),
            browserID: browser.id,
            label: label,
            profileIdentifier: profile?.identifier,
            profileDisplayName: profile?.displayName,
            mode: mode,
            isEnabled: mode == .normal,
            sortOrder: 0,
            origin: .detected,
            availability: .available
        )
    }

    private static func merging(
        _ discovered: BrowserTarget,
        preserving existing: BrowserTarget
    ) -> BrowserTarget {
        BrowserTarget(
            id: discovered.id,
            browserID: discovered.browserID,
            label: existing.label,
            profileIdentifier: discovered.profileIdentifier,
            profileDisplayName: discovered.profileDisplayName,
            mode: discovered.mode,
            isEnabled: existing.isEnabled,
            sortOrder: existing.sortOrder,
            origin: existing.origin,
            availability: .available,
            validationError: nil
        )
    }
}
