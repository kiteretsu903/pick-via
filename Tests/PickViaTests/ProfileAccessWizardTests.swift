import Foundation
import PickViaCore
import XCTest

@testable import PickVia

@MainActor
final class ProfileAccessWizardTests: XCTestCase {
  func testSkipEndsPresentationCancelsOutstandingSelectionAndIgnoresLateGrant() async throws {
    let selector = SuspendingProfileAccessFolderSelectorSpy()
    let coordinator = ProfileAccessWizardSelectionCoordinator(folderSelector: selector)
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )
    var grantedRoots: [URL] = []
    var skipCallCount = 0
    coordinator.beginPresentation()
    XCTAssertTrue(
      coordinator.selectRoot(for: chrome) { root in
        grantedRoots.append(root)
      }
    )
    await selector.waitUntilSelectionBegins()

    coordinator.performSkip {
      skipCallCount += 1
    }
    XCTAssertEqual(selector.cancelCallCount, 1)
    XCTAssertEqual(skipCallCount, 1)

    selector.resolveSelection(with: URL(fileURLWithPath: "/chosen/Chrome"))
    await waitUntilSelectionCompletes(coordinator)
    XCTAssertTrue(grantedRoots.isEmpty)
  }

  func testFinishCancelsOutstandingSelectionAndIgnoresLateGrant() async throws {
    let selector = SuspendingProfileAccessFolderSelectorSpy()
    let coordinator = ProfileAccessWizardSelectionCoordinator(folderSelector: selector)
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )
    var grantedRoots: [URL] = []
    var finishCallCount = 0
    coordinator.beginPresentation()
    XCTAssertTrue(
      coordinator.selectRoot(for: chrome) { root in
        grantedRoots.append(root)
      }
    )
    await selector.waitUntilSelectionBegins()

    coordinator.performFinish {
      finishCallCount += 1
    }
    XCTAssertEqual(selector.cancelCallCount, 1)
    XCTAssertEqual(finishCallCount, 1)

    selector.resolveSelection(with: URL(fileURLWithPath: "/chosen/Chrome"))
    await waitUntilSelectionCompletes(coordinator)
    XCTAssertTrue(grantedRoots.isEmpty)
  }

  func testWizardCoordinatorRejectsConcurrentSelectionAcrossRows() async throws {
    let selector = SuspendingProfileAccessFolderSelectorSpy()
    let coordinator = ProfileAccessWizardSelectionCoordinator(folderSelector: selector)
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )
    let edge = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.microsoft.edgemac")
    )
    coordinator.beginPresentation()

    XCTAssertTrue(coordinator.selectRoot(for: chrome) { _ in })
    await selector.waitUntilSelectionBegins()
    XCTAssertFalse(coordinator.selectRoot(for: edge) { _ in })
    XCTAssertEqual(selector.selectCallCount, 1)

    selector.resolveSelection(with: nil)
    await waitUntilSelectionCompletes(coordinator)
  }

  func testPresentationEndingBeforeSelectionTaskStartsNeverInvokesSelector() async throws {
    let selector = SuspendingProfileAccessFolderSelectorSpy()
    let coordinator = ProfileAccessWizardSelectionCoordinator(folderSelector: selector)
    let chrome = try XCTUnwrap(
      BrowserDescriptor.descriptor(forBundleIdentifier: "com.google.Chrome")
    )
    coordinator.beginPresentation()

    XCTAssertTrue(coordinator.selectRoot(for: chrome) { _ in })
    coordinator.performSkip {}

    for _ in 0..<10 {
      await Task.yield()
    }
    XCTAssertEqual(selector.selectCallCount, 0)
    if selector.selectCallCount > 0 {
      selector.resolveSelection(with: nil)
    }
  }

  func testApprovedStatusText() {
    XCTAssertEqual(profileAccessStatusText(for: .accessNeeded), "Access needed")
    XCTAssertEqual(
      profileAccessStatusText(for: .granted(profileCount: 3, persistence: .persistent)),
      "Granted — 3 profiles found"
    )
    XCTAssertEqual(
      profileAccessStatusText(for: .granted(profileCount: 1, persistence: .persistent)),
      "Granted — 1 profile found"
    )
    XCTAssertEqual(
      profileAccessStatusText(for: .invalidFolder(requiredMarker: "Local State")),
      "Invalid folder"
    )
    XCTAssertEqual(profileAccessStatusText(for: .accessRevoked), "Access revoked")
    XCTAssertEqual(profileAccessStatusText(for: .metadataDamaged), "Metadata damaged")
  }

  func testAccessActionLabelsMatchApprovedCopy() {
    XCTAssertEqual(
      profileAccessPrimaryAction(for: .accessNeeded, hasStoredGrant: false),
      "Grant Access"
    )
    XCTAssertEqual(
      profileAccessPrimaryAction(
        for: .invalidFolder(requiredMarker: "Local State"),
        hasStoredGrant: false
      ),
      "Grant Access"
    )
    XCTAssertEqual(
      profileAccessPrimaryAction(
        for: .invalidFolder(requiredMarker: "Local State"),
        hasStoredGrant: true
      ),
      "Replace Access"
    )
    XCTAssertEqual(
      profileAccessPrimaryAction(for: .accessRevoked, hasStoredGrant: true),
      "Replace Access"
    )
    XCTAssertNil(
      profileAccessPrimaryAction(
        for: .granted(profileCount: 2, persistence: .persistent),
        hasStoredGrant: true
      )
    )
    XCTAssertNil(
      profileAccessPrimaryAction(for: .metadataDamaged, hasStoredGrant: true)
    )
  }

  func testFinishEligibilityRequiresAtLeastOneUsableGrant() {
    XCTAssertFalse(profileAccessCanFinish(rows: []))
    XCTAssertFalse(
      profileAccessCanFinish(rows: [row(state: .accessNeeded, hasStoredGrant: false)])
    )
    XCTAssertTrue(
      profileAccessCanFinish(
        rows: [
          row(state: .granted(profileCount: 1, persistence: .persistent), hasStoredGrant: true)
        ]
      )
    )
    XCTAssertTrue(
      profileAccessCanFinish(
        rows: [
          row(
            state: .invalidFolder(requiredMarker: "Local State"),
            hasStoredGrant: true
          )
        ]
      )
    )
  }

  func testGuidanceUsesOnlyApprovedMarkerAndSessionRecoveryCopy() {
    XCTAssertEqual(
      profileAccessGuidanceText(
        for: .invalidFolder(requiredMarker: "Local State"),
        requiredMarker: "Local State"
      ),
      "Select the browser data folder containing Local State."
    )
    XCTAssertEqual(
      profileAccessGuidanceText(
        for: .invalidFolder(requiredMarker: "/Users/private/profiles.ini"),
        requiredMarker: "profiles.ini"
      ),
      "Select the browser data folder containing profiles.ini."
    )
    XCTAssertEqual(
      profileAccessGuidanceText(
        for: .granted(profileCount: 1, persistence: .currentSessionOnly),
        requiredMarker: "Local State"
      ),
      "Access is available until PickVia quits. To avoid granting it again, allow PickVia in Full Disk Access."
    )
  }

  func testWizardCommitErrorUsesModelSanitizedCopyWithoutRawErrorOrPath() throws {
    let model = makeOnboardingModel(step: 3)
    try model.load()
    model.reportProfileAccessCommitFailure()

    let rendered = try XCTUnwrap(profileAccessWizardErrorText(model.errorMessage))

    XCTAssertEqual(
      rendered,
      "Browser discovery produced a configuration that could not be committed."
    )
    XCTAssertFalse(rendered.contains("/Users/"))
    XCTAssertNil(profileAccessWizardErrorText(nil))
  }

  func testWizardSourceContainsApprovedControlsAndNoRejectedCopy() throws {
    let sources = try String(
      contentsOf: repositoryRoot.appending(
        path: "Sources/PickVia/Views/ProfileAccessWizardView.swift"),
      encoding: .utf8
    )

    for label in [
      "Grant Access", "Replace Access", "Remove Access", "Finish & Rescan", "Skip for Now",
    ] {
      XCTAssertTrue(sources.contains(label), "Missing approved label: \(label)")
    }
    XCTAssertFalse(sources.contains("Choose Folder"))
  }

  func testDurableEntryPointsSharePresenterAndUseExplicitUserRescan() throws {
    let settings = try source("Sources/PickVia/Views/BrowserSettingsView.swift")
    let welcome = try source("Sources/PickVia/Views/WelcomeView.swift")
    let statusMenu = try source("Sources/PickVia/Views/StatusMenuView.swift")
    let app = try source("Sources/PickVia/App/PickViaApp.swift")

    XCTAssertTrue(settings.contains("Label(\"Profile Access\", systemImage: \"folder.badge.key\")"))
    XCTAssertTrue(settings.contains("model.openProfileAccessManager()"))
    XCTAssertTrue(settings.contains("profileAccessPresenter.request(model: model)"))
    XCTAssertTrue(settings.contains("profileAccessPresenter.environmentDidChange()"))

    XCTAssertEqual(
      statusMenu.components(separatedBy: ".disabled(!model.canPresentOrdinaryAppSurface)").count
        - 1,
      2
    )
    XCTAssertEqual(
      statusMenu.components(separatedBy: ".disabled(!settingsNavigationAction.isEnabled)").count
        - 1,
      1
    )
    XCTAssertTrue(statusMenu.contains("private var aboutAction: AboutAction"))
    XCTAssertTrue(statusMenu.contains("aboutAction.show()"))
    XCTAssertTrue(statusMenu.contains(".disabled(!aboutAction.isEnabled)"))
    XCTAssertFalse(statusMenu.contains("showAboutIfAllowed"))

    for sources in [settings, welcome, statusMenu] {
      XCTAssertTrue(sources.contains("model.userRequestedRescan()"))
      XCTAssertTrue(sources.contains("profileAccessPresenter.requestIfPending(model: model)"))
      XCTAssertFalse(sources.contains("model.rescan()"))
    }

    XCTAssertEqual(
      app.components(separatedBy: ".environment(\\.profileAccessPresenter").count - 1,
      3
    )
  }

  func testAppExplicitlyReplacesAutomaticSettingsCommandWithGuardedCommand() throws {
    let app = try source("Sources/PickVia/App/PickViaApp.swift")

    XCTAssertEqual(
      app.components(separatedBy: "CommandGroup(replacing: .appSettings)").count - 1,
      1
    )
    XCTAssertEqual(app.components(separatedBy: "Button(\"Settings…\")").count - 1, 1)
    XCTAssertTrue(app.contains("delegate.settingsNavigationAction.open(.general)"))
    XCTAssertTrue(app.contains(".disabled(!delegate.settingsNavigationAction.isEnabled)"))
    XCTAssertTrue(app.contains(".keyboardShortcut(\",\", modifiers: .command)"))
  }

  func testAppExplicitlyReplacesAutomaticAboutCommandWithSharedGuardedAction() throws {
    let app = try source("Sources/PickVia/App/PickViaApp.swift")
    let statusMenu = try source("Sources/PickVia/Views/StatusMenuView.swift")

    XCTAssertEqual(
      app.components(separatedBy: "CommandGroup(replacing: .appInfo)").count - 1,
      1
    )
    XCTAssertEqual(app.components(separatedBy: "Button(\"About PickVia\")").count - 1, 1)
    XCTAssertTrue(app.contains("delegate.aboutAction.show()"))
    XCTAssertTrue(app.contains(".disabled(!delegate.aboutAction.isEnabled)"))
    XCTAssertFalse(app.contains("orderFrontStandardAboutPanel"))

    XCTAssertEqual(statusMenu.components(separatedBy: "Button(\"About PickVia\")").count - 1, 1)
    XCTAssertTrue(statusMenu.contains("AboutAction("))
    XCTAssertTrue(statusMenu.contains("aboutAction.show()"))
    XCTAssertTrue(statusMenu.contains(".disabled(!aboutAction.isEnabled)"))
  }

  func testReviewContinueRequestsPendingWizardAfterAdvancingToDefaultStep() throws {
    let presenter = ProfileAccessWizardPresenterSpy()
    let model = makeOnboardingModel(step: 2)
    try model.load()

    advanceOnboardingAndPresentProfileAccess(
      model: model,
      profileAccessPresenter: presenter
    )

    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertEqual(presenter.requestIfPendingCallCount, 1)
    XCTAssertTrue(presenter.lastModel === model)
  }

  func testReviewContinueKeepsDefaultRequestDisabledWhileWizardIsQueued() throws {
    let driver = QueuedProfileAccessPanelDriver()
    let presenter = ProfileAccessPanelController(driver: driver)
    let model = makeOnboardingModel(step: 2, profileAccessRequired: true)
    try model.load()

    advanceOnboardingAndPresentProfileAccess(
      model: model,
      profileAccessPresenter: presenter
    )

    XCTAssertEqual(model.onboardingStep, 3)
    XCTAssertEqual(model.profileAccessPresentation, .automaticPending)
    XCTAssertFalse(model.canRequestDefaultBrowser)
    XCTAssertEqual(driver.presentCallCount, 0)
  }

  private func source(_ path: String) throws -> String {
    try String(contentsOf: repositoryRoot.appending(path: path), encoding: .utf8)
  }

  private func makeOnboardingModel(
    step: Int,
    profileAccessRequired: Bool = false
  ) -> AppModel {
    AppModel(
      configStore: ProfileAccessWizardConfigStoreStub(),
      browserCatalog: ProfileAccessWizardCatalogStub(
        profileAccessRequired: profileAccessRequired
      ),
      preferences: ProfileAccessWizardPreferencesStub(step: step),
      defaultBrowser: ProfileAccessWizardDefaultHandlerStub(),
      loginItem: ProfileAccessWizardLoginItemStub(),
      routing: ProfileAccessWizardRoutingStub()
    )
  }

  private func row(
    state: BrowserProfileAccessRowState,
    hasStoredGrant: Bool
  ) -> BrowserProfileAccessRow {
    BrowserProfileAccessRow(
      bundleIdentifier: "com.google.Chrome",
      displayName: "Google Chrome",
      family: .chromium,
      expectedRootSuffix: "Library/Application Support/Google/Chrome",
      requiredMarker: "Local State",
      state: state,
      hasStoredGrant: hasStoredGrant
    )
  }

  private func waitUntilSelectionCompletes(
    _ coordinator: ProfileAccessWizardSelectionCoordinator
  ) async {
    for _ in 0..<100 where coordinator.isSelectionInFlight {
      await Task.yield()
    }
    XCTAssertFalse(coordinator.isSelectionInFlight)
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

@MainActor
private final class SuspendingProfileAccessFolderSelectorSpy: ProfileAccessFolderSelecting {
  private(set) var selectCallCount = 0
  private(set) var cancelCallCount = 0
  private var continuation: CheckedContinuation<URL?, Never>?

  func selectRoot(for descriptor: BrowserDescriptor) async -> URL? {
    selectCallCount += 1
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func cancelSelection() {
    cancelCallCount += 1
  }

  func waitUntilSelectionBegins() async {
    while selectCallCount == 0 {
      await Task.yield()
    }
  }

  func resolveSelection(with result: URL?) {
    let pendingContinuation = continuation
    continuation = nil
    pendingContinuation?.resume(returning: result)
  }
}

@MainActor
private final class QueuedProfileAccessPanelDriver: ProfileAccessPanelDriving {
  var environmentDidChangeHandler: (@MainActor () -> Void)?
  var canPresent = false
  private(set) var presentCallCount = 0

  func hideCompetingPickViaWindows() {}
  func present(model: AppModel, onClose: @escaping @MainActor () -> Void) -> Bool {
    presentCallCount += 1
    return true
  }
  func dismissAndRestoreWindows() {}
}

@MainActor
private final class ProfileAccessWizardPresenterSpy: ProfileAccessPresenting {
  private(set) var requestIfPendingCallCount = 0
  private(set) weak var lastModel: AppModel?

  func request(model: AppModel) { lastModel = model }
  func requestIfPending(model: AppModel) {
    requestIfPendingCallCount += 1
    lastModel = model
  }
  func environmentDidChange() {}
  func dismiss() {}
}

private struct ProfileAccessWizardConfigStoreStub: ConfigStoring {
  func load() throws -> PickViaConfig { .initial }
  func save(_ config: PickViaConfig) throws {}
}

private struct ProfileAccessWizardCatalogStub: BrowserDiscovering {
  let profileAccessRequired: Bool

  init(profileAccessRequired: Bool = false) {
    self.profileAccessRequired = profileAccessRequired
  }

  func scan() throws -> [DiscoveredBrowser] { scanResult().browsers }
  func scanResult() -> BrowserScanResult {
    if profileAccessRequired {
      return BrowserScanResult(
        browsers: [ProfileAccessWizardFixtures.blockedChrome],
        profileAccessIssues: [
          .accessRequired(
            bundleIdentifier: ProfileAccessWizardFixtures.application.bundleIdentifier)
        ]
      )
    }
    return BrowserScanResult(
      browsers: [ProfileAccessWizardFixtures.chrome],
      profileAccessIssues: []
    )
  }
  func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig {
    PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      browsers: discovered.map(\.application),
      targets: [ProfileAccessWizardFixtures.target]
    )
  }
}

@MainActor
private final class ProfileAccessWizardPreferencesStub: PreferencesStoring {
  let step: Int
  init(step: Int) { self.step = step }
  func bool(forKey key: String) -> Bool? { nil }
  func integer(forKey key: String) -> Int? { key == "onboardingStep" ? step : nil }
  func set(_ value: Bool, forKey key: String) {}
  func set(_ value: Int, forKey key: String) {}
}

@MainActor
private final class ProfileAccessWizardDefaultHandlerStub: DefaultHandlerServicing {
  func status() -> DefaultHandlerStatus { .unknown }
  func requestDefault(for schemes: [String]) async throws {}
}

@MainActor
private final class ProfileAccessWizardLoginItemStub: LoginItemServicing {
  var isEnabled: Bool { false }
  func setEnabled(_ enabled: Bool) throws {}
}

@MainActor
private final class ProfileAccessWizardRoutingStub: AppRouting {
  func accept(_ url: URL) {}
  func preview(_ url: URL) {}
}

private enum ProfileAccessWizardFixtures {
  static let application = BrowserApplication(
    id: "com.google.Chrome",
    family: .chromium,
    displayName: "Google Chrome",
    bundleIdentifier: "com.google.Chrome",
    applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
    executableURL: nil,
    isAvailable: true
  )
  static let target = BrowserTarget(
    id: "chrome-default",
    browserID: application.id,
    label: "Google Chrome",
    profileIdentifier: nil,
    profileDisplayName: nil,
    mode: .normal,
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: .available
  )
  static let chrome = DiscoveredBrowser(
    application: application,
    profiles: [],
    metadataStatus: .loaded
  )
  static let blockedChrome = DiscoveredBrowser(
    application: application,
    profiles: [],
    metadataStatus: .accessRequired
  )
}
