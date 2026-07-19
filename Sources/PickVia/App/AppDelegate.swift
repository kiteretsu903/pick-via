import AppKit
import Foundation
import PickViaCore
import SwiftUI

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
    guard model.onboardingStep >= 3,
      model.shouldAutomaticallyPresentProfileAccess
    else { return }

    launchScheduler.schedule { [weak self] in
      guard let self else { return }
      self.profileAccessPresenter.requestIfPending(model: self.model)
    }
  }

  public func applicationDidBecomeActive(_ notification: Notification) {
    model.refreshDefaultStatus()
    profileAccessPresenter.environmentDidChange()
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

extension AppModel {
  static func production(
    navigation: SettingsNavigation,
    openSettings: @escaping @MainActor () -> Void
  ) -> (model: AppModel, profileAccessPresenter: any ProfileAccessPresenting) {
    let applicationSupportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appending(path: "PickVia", directoryHint: .isDirectory)
    let configStore = JSONConfigStore(directory: applicationSupportDirectory)
    let profileAccessStore = JSONProfileAccessStore(directory: applicationSupportDirectory)
    let profileAccessCoordinator = ProfileAccessCoordinator(store: profileAccessStore)
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
    let preferences = UserDefaultsPreferences()
    let recovery = BrowserSettingsRecovery(
      navigation: navigation,
      openSettings: openSettings
    )
    let chooser = ChooserPanelController(
      showsURLProvider: {
        preferences.bool(forKey: PreferenceKey.showsURLInChooser) ?? true
      },
      clipboard: SystemClipboardWriter(),
      openBrowserSettings: recovery.open,
      onPresentationChange: { [weak profileAccessPresenter] _ in
        profileAccessPresenter?.environmentDidChange()
      }
    )
    chooserActivity.chooser = chooser
    let model = AppComposition.makeModel(
      configStore: configStore,
      browserCatalog: BrowserCatalog(profileRootAccess: profileAccessCoordinator),
      preferences: preferences,
      defaultBrowser: MacOSDefaultBrowserService(),
      loginItem: MacOSLoginItemService(),
      chooser: chooser,
      launcher: BrowserLauncher(),
      profileAccess: profileAccessCoordinator,
      profileRootValidator: profileRootValidator
    )
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
    return (model, profileAccessPresenter)
  }
}

@MainActor
private final class ChooserPresentationActivity {
  weak var chooser: ChooserPanelController?
}

@MainActor
enum AppComposition {
  static func makeModel(
    configStore: any ConfigStoring,
    browserCatalog: any BrowserDiscovering,
    preferences: any PreferencesStoring,
    defaultBrowser: any DefaultBrowserServicing,
    loginItem: any LoginItemServicing,
    chooser: any ChooserPresenting,
    launcher: any BrowserLaunching,
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
      preferences: preferences,
      defaultBrowser: defaultBrowser,
      loginItem: loginItem,
      routing: routing,
      targetSnapshot: targetProvider,
      profileAccess: profileAccess,
      profileRootValidator: profileRootValidator
    )
  }
}

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
    let snapshot = targetProvider.availableSnapshot()
    chooser.present(
      request: RoutingRequest(url: url),
      applications: snapshot.applications,
      targets: snapshot.targets,
      error: nil,
      onSelection: { [weak self] _ in self?.chooser.dismiss() },
      onCancel: { [weak self] in self?.chooser.dismiss() }
    )
  }
}
