import AppKit
import Foundation
import PickViaCore
import SwiftUI

#if PICKVIA_E2E_AUTOMATION
  import Darwin
#endif

@MainActor
protocol AppLaunchScheduling: AnyObject {
  func schedule(_ action: @escaping @MainActor @Sendable () -> Void)
}

@MainActor
final class MainRunLoopAppLaunchScheduler: AppLaunchScheduling {
  func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async(execute: action)
  }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
  public let model: AppModel
  public let navigation: SettingsNavigation
  public let profileAccessPresenter: any ProfileAccessPresenting
  let settingsSceneOpener: SettingsSceneOpener

  private let windowSpaceCoordinator: any AppWindowSpaceCoordinating
  private let chooserPrewarmer: any ChooserPrewarming
  private let launchScheduler: any AppLaunchScheduling
  private let openSettings: @MainActor () -> Void
  private let showAbout: @MainActor () -> Void

  var settingsNavigationAction: SettingsNavigationAction {
    SettingsNavigationAction(
      model: model,
      navigation: navigation,
      openSettings: openSettings
    )
  }

  var aboutAction: AboutAction {
    AboutAction(model: model, showAboutPanel: showAbout)
  }

  public override convenience init() {
    let navigation = SettingsNavigation()
    let settingsSceneOpener = SettingsSceneOpener()
    let activateApplication: @MainActor () -> Void = {
      NSApp.activate(ignoringOtherApps: true)
    }
    let openSettings: @MainActor () -> Void = {
      activateApplication()
      settingsSceneOpener.open()
    }
    let showAbout: @MainActor () -> Void = {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.orderFrontStandardAboutPanel(nil)
    }
    let production = AppModel.production(
      navigation: navigation,
      openSettings: openSettings
    )
    self.init(
      model: production.model,
      navigation: navigation,
      profileAccessPresenter: production.profileAccessPresenter,
      settingsSceneOpener: settingsSceneOpener,
      chooserPrewarmer: production.chooserPrewarmer,
      openSettings: openSettings,
      showAbout: showAbout
    )
  }

  init(
    model: AppModel,
    navigation: SettingsNavigation = SettingsNavigation(),
    profileAccessPresenter: any ProfileAccessPresenting = InactiveAppDelegateProfileAccessPresenter
      .shared,
    settingsSceneOpener: SettingsSceneOpener = SettingsSceneOpener(),
    windowSpaceCoordinator: any AppWindowSpaceCoordinating = AppWindowSpaceCoordinator(),
    chooserPrewarmer: any ChooserPrewarming = InactiveChooserPrewarmer.shared,
    launchScheduler: any AppLaunchScheduling = MainRunLoopAppLaunchScheduler(),
    openSettings: @escaping @MainActor () -> Void,
    showAbout: @escaping @MainActor () -> Void = {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.orderFrontStandardAboutPanel(nil)
    }
  ) {
    self.model = model
    self.navigation = navigation
    self.profileAccessPresenter = profileAccessPresenter
    self.settingsSceneOpener = settingsSceneOpener
    self.windowSpaceCoordinator = windowSpaceCoordinator
    self.chooserPrewarmer = chooserPrewarmer
    self.launchScheduler = launchScheduler
    self.openSettings = openSettings
    self.showAbout = showAbout
    super.init()
  }

  public func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      model.accept(url: url)
    }
  }

  public func applicationDidFinishLaunching(_ notification: Notification) {
    if model.configurationRecovery != .none {
      navigation.destination = .browsers
      openSettings()
      return
    }
    let shouldRequestPendingProfileAccess =
      model.onboardingStep >= 3 && model.shouldAutomaticallyPresentProfileAccess

    launchScheduler.schedule { [weak self] in
      guard let self else { return }
      self.chooserPrewarmer.prepare(
        applications: self.model.browsers,
        targets: self.model.targets
      )
      if shouldRequestPendingProfileAccess {
        self.profileAccessPresenter.requestIfPending(model: self.model)
      }
    }
  }

  public func applicationDidBecomeActive(_ notification: Notification) {
    model.refreshDefaultStatus()
    profileAccessPresenter.environmentDidChange()
  }

  public func applicationWillBecomeActive(_ notification: Notification) {
    windowSpaceCoordinator.prepareVisibleWindowsForActivation()
  }

  public func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    settingsNavigationAction.open(.general)
  }
}

@MainActor
private final class InactiveAppDelegateProfileAccessPresenter: ProfileAccessPresenting {
  static let shared = InactiveAppDelegateProfileAccessPresenter()

  func request(model: AppModel) {}
  func requestIfPending(model: AppModel) {}
  func environmentDidChange() {}
  func dismiss() {}
}

@MainActor
private final class InactiveChooserPrewarmer: ChooserPrewarming {
  static let shared = InactiveChooserPrewarmer()

  func prepare(applications: [BrowserApplication], targets: [BrowserTarget]) {}
}

extension AppModel {
  static func production(
    navigation: SettingsNavigation,
    openSettings: @escaping @MainActor () -> Void
  ) -> (
    model: AppModel,
    profileAccessPresenter: any ProfileAccessPresenting,
    chooserPrewarmer: any ChooserPrewarming
  ) {
    #if PICKVIA_E2E_AUTOMATION
      guard
        E2EAutomationMarker.isPresent(in: .main),
        let e2eControl = E2EApplicationEnvironment.validatedControl(
          environment: ProcessInfo.processInfo.environment,
          onFailure: { E2EControlFailure.terminateProcess() }
        )
      else {
        preconditionFailure("E2E configuration termination returned unexpectedly")
      }
      let applicationSupportDirectory = E2EApplicationEnvironment.applicationSupportDirectory(
        control: e2eControl
      )
    #else
      let applicationSupportDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      )[0].appending(path: "PickVia", directoryHint: .isDirectory)
    #endif
    let configStore = JSONConfigStore(directory: applicationSupportDirectory)
    let profileAccessStore = JSONProfileAccessStore(directory: applicationSupportDirectory)
    let profileAccessCoordinator = ProfileAccessCoordinator(store: profileAccessStore)
    #if PICKVIA_E2E_AUTOMATION
      do {
        try E2EProfileGrantInstaller.installIfPresent(
          control: e2eControl,
          descriptors: BrowserDescriptor.supported,
          coordinator: profileAccessCoordinator
        )
      } catch {
        E2EControlFailure.terminateProcess()
        preconditionFailure("E2E profile-grant termination returned unexpectedly")
      }
    #endif
    let profileRootValidator = BrowserProfileRootValidator()
    let profileAccessFolderSelector = ProfileAccessFolderSelector()
    let profileAccessSelectionCoordinator = ProfileAccessWizardSelectionCoordinator(
      folderSelector: profileAccessFolderSelector
    )
    let chooserActivity = ChooserPresentationActivity()
    let profileAccessPanelDriver = AppKitProfileAccessPanelDriver(
      isChooserActive: { chooserActivity.chooser?.hasActivePresentation == true }
    )
    let profileAccessPresenter = ProfileAccessPanelController(
      driver: profileAccessPanelDriver,
      selectionCoordinator: profileAccessSelectionCoordinator
    )
    let preferences = AppComposition.makePreferences()
    let ordinaryChooser = ChooserPanelController(
      showsURLProvider: {
        preferences.bool(forKey: PreferenceKey.showsURLInChooser) ?? true
      },
      densityProvider: {
        ChooserDensity.fromPersistedValue(
          preferences.integer(forKey: PreferenceKey.chooserDensity)
        )
      },
      clipboard: SystemClipboardWriter(),
      openSettings: AppComposition.makeChooserSettingsHandler(
        navigation: navigation,
        openSettings: openSettings,
        chooserSettingsDidOpen: { [weak chooserActivity] kind in
          chooserActivity?.model?.chooserSettingsDidOpen(for: kind)
        }
      ),
      onPresentationChange: { [weak profileAccessPresenter] _ in
        profileAccessPresenter?.environmentDidChange()
      }
    )
    chooserActivity.chooser = ordinaryChooser
    #if PICKVIA_E2E_AUTOMATION
      let chooser: any ChooserPresenting = AppComposition.makeChooser(
        ordinary: ordinaryChooser,
        e2eControl: e2eControl,
        statusWriter: E2EStatusWriter()
      )
    #else
      let chooser: any ChooserPresenting = ordinaryChooser
    #endif
    #if PICKVIA_E2E_AUTOMATION
      let browserCatalog: any BrowserDiscovering = E2EApplicationEnvironment.browserCatalog(
        control: e2eControl,
        profileRootAccess: profileAccessCoordinator
      )
    #else
      let browserCatalog: any BrowserDiscovering = BrowserCatalog(
        profileRootAccess: profileAccessCoordinator
      )
    #endif
    #if PICKVIA_E2E_AUTOMATION
      let browserLauncher = BrowserLauncher(
        provenanceContext: E2EApplicationEnvironment.launchProvenanceContext(
          control: e2eControl
        ),
        provenanceSink: E2ELaunchProvenanceWriter(fifo: e2eControl.provenanceFIFO)
      )
    #else
      let browserLauncher = BrowserLauncher()
    #endif
    let model = AppComposition.makeModel(
      configStore: configStore,
      browserCatalog: browserCatalog,
      mailCatalog: MailCatalog(
        pickViaBundleIdentifier: Bundle.main.bundleIdentifier!
      ),
      preferences: preferences,
      defaultBrowser: MacOSDefaultHandlerService(),
      loginItem: MacOSLoginItemService(),
      chooser: chooser,
      launcher: RouteLauncher(
        browserLauncher: browserLauncher,
        mailLauncher: MailLauncher(
          pickViaBundleIdentifier: Bundle.main.bundleIdentifier!
        )
      ),
      profileAccess: profileAccessCoordinator,
      profileRootValidator: profileRootValidator
    )
    chooserActivity.model = model
    profileAccessPanelDriver.attachWizardViewFactory { [weak profileAccessPresenter] model in
      AnyView(
        ProfileAccessWizardView(
          selectionCoordinator: profileAccessSelectionCoordinator,
          dismissWizard: { profileAccessPresenter?.dismiss() }
        )
        .environment(model)
      )
    }

    try? model.load()
    return (model, profileAccessPresenter, ordinaryChooser)
  }
}

@MainActor
private final class ChooserPresentationActivity {
  weak var chooser: ChooserPanelController?
  weak var model: AppModel?
}

@MainActor
enum AppComposition {
  static func makePreferences() -> any PreferencesStoring {
    #if PICKVIA_E2E_AUTOMATION
      E2EEphemeralPreferences()
    #else
      UserDefaultsPreferences()
    #endif
  }

  #if PICKVIA_E2E_AUTOMATION
    static func makeChooser(
      ordinary: any ChooserPresenting,
      e2eControl: E2EControl,
      statusWriter: any E2EStatusWriting
    ) -> any ChooserPresenting {
      E2EChooserPresenter(
        base: ordinary,
        control: e2eControl,
        statusWriter: statusWriter
      )
    }
  #endif

  static func makeModel(
    configStore: any ConfigStoring,
    browserCatalog: any BrowserDiscovering,
    mailCatalog: any MailDiscovering,
    preferences: any PreferencesStoring,
    defaultBrowser: any DefaultHandlerServicing,
    loginItem: any LoginItemServicing,
    chooser: any ChooserPresenting,
    launcher: any RouteLaunching,
    profileAccess: any ProfileAccessManaging = MissingProfileAccessManager(),
    profileRootValidator: BrowserProfileRootValidator = BrowserProfileRootValidator()
  ) -> AppModel {
    let targetProvider = MutableTargetSnapshot()
    let coordinator = RoutingCoordinator(
      targetProvider: targetProvider,
      chooser: chooser,
      launcher: launcher
    )
    let preview = PreviewPresenter(
      targetProvider: targetProvider,
      chooser: chooser,
      canPresent: { [weak coordinator] in
        coordinator?.currentRequest == nil
      }
    )
    let routing = RoutingCoordinatorAdapter(
      coordinator: coordinator,
      previewAction: preview.present
    )
    return AppModel(
      configStore: configStore,
      browserCatalog: browserCatalog,
      mailCatalog: mailCatalog,
      preferences: preferences,
      defaultBrowser: defaultBrowser,
      loginItem: loginItem,
      routing: routing,
      targetSnapshot: targetProvider,
      profileAccess: profileAccess,
      profileRootValidator: profileRootValidator
    )
  }

  static func makeChooserSettingsHandler(
    navigation: SettingsNavigation,
    openSettings: @escaping @MainActor () -> Void,
    chooserSettingsDidOpen: @escaping @MainActor (RouteKind) -> Void = { _ in }
  ) -> @MainActor (RouteKind) -> Void {
    { kind in
      chooserSettingsDidOpen(kind)
      switch kind {
      case .web:
        navigation.destination = .browsers
      case .mail:
        navigation.destination = .mail
      }
      openSettings()
    }
  }
}

#if PICKVIA_E2E_AUTOMATION
  enum E2EAutomationMarker {
    static let value = "PICKVIA_E2E_AUTOMATION_ENABLED"

    static func isPresent(in bundle: Bundle) -> Bool {
      bundle.object(forInfoDictionaryKey: "PickViaE2EAutomationMarker") as? String == value
    }
  }

  enum E2EApplicationEnvironment {
    static func validatedControl(
      environment: [String: String],
      onFailure: () -> Void
    ) -> E2EControl? {
      guard let control = E2EControl.load(environment: environment) else {
        onFailure()
        return nil
      }
      return control
    }

    static func applicationSupportDirectory(control: E2EControl) -> URL {
      control.applicationSupportDirectory
    }

    static func launchProvenanceContext(
      control: E2EControl
    ) -> BrowserLaunchProvenanceContext {
      BrowserLaunchProvenanceContext(
        sessionNonce: control.sessionNonce,
        requestNonce: control.requestNonce,
        targetID: control.targetID,
        expectedBundleIdentifier: control.expectedBundleIdentifier,
        mode: control.expectedMode
      )
    }

    static func browserCatalog(
      control: E2EControl,
      descriptors: [BrowserDescriptor] = BrowserDescriptor.supported,
      applicationLocator: any ApplicationLocating = WorkspaceApplicationLocator(),
      fileSystem: any FileSystem = FoundationFileSystem(),
      profileRootAccess: any ProfileRootAccessProviding,
      duckDuckGoCompatibilityChecker: any DuckDuckGoBuildCompatibilityChecking =
        DuckDuckGoBuildCompatibilityChecker()
    ) -> BrowserCatalog {
      BrowserCatalog(
        descriptors: descriptors,
        applicationLocator: applicationLocator,
        fileSystem: fileSystem,
        profileRootAccess: profileRootAccess,
        duckDuckGoCompatibilityChecker: duckDuckGoCompatibilityChecker,
        homeDirectory: control.applicationSupportDirectory
      )
    }
  }

  @MainActor
  final class E2EEphemeralPreferences: PreferencesStoring {
    private var booleans: [String: Bool] = [:]
    private var integers: [String: Int] = [:]

    func bool(forKey key: String) -> Bool? { booleans[key] }
    func integer(forKey key: String) -> Int? { integers[key] }
    func set(_ value: Bool, forKey key: String) { booleans[key] = value }
    func set(_ value: Int, forKey key: String) { integers[key] = value }
  }

  enum E2EControlFailure {
    private static let diagnostic = "PickVia E2E configuration is invalid.\n"

    static func terminateProcess(
      writeDiagnostic: (String) -> Void = { message in
        FileHandle.standardError.write(Data(message.utf8))
      },
      terminate: (Int32) -> Void = { status in Darwin.exit(status) }
    ) {
      writeDiagnostic(diagnostic)
      terminate(Int32(EX_CONFIG))
    }
  }
#endif

@MainActor
private final class PreviewPresenter {
  private let targetProvider: any TargetProviding
  private let chooser: any ChooserPresenting
  private let canPresent: @MainActor () -> Bool

  init(
    targetProvider: any TargetProviding,
    chooser: any ChooserPresenting,
    canPresent: @escaping @MainActor () -> Bool
  ) {
    self.targetProvider = targetProvider
    self.chooser = chooser
    self.canPresent = canPresent
  }

  func present(_ url: URL) {
    guard canPresent() else { return }
    guard let validated = try? URLValidator.validate(url) else { return }
    let snapshot = targetProvider.availableSnapshot(for: validated.kind)
    chooser.present(
      request: RoutingRequest(kind: validated.kind, url: validated.url),
      applications: snapshot.applications,
      targets: snapshot.targets,
      error: nil,
      onSelection: { [weak self] _ in self?.chooser.dismiss() },
      onCancel: { [weak self] in self?.chooser.dismiss() }
    )
  }
}
