import AppKit
import Foundation
import PickViaCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
  public let model: AppModel
  public let navigation: SettingsNavigation

  private let openSettings: @MainActor () -> Void

  public override convenience init() {
    let navigation = SettingsNavigation()
    let openSettings: @MainActor () -> Void = {
      NSApp.activate(ignoringOtherApps: true)
      _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    self.init(
      model: AppModel.production(
        navigation: navigation,
        openSettings: openSettings
      ),
      navigation: navigation,
      openSettings: openSettings
    )
  }

  init(
    model: AppModel,
    navigation: SettingsNavigation = SettingsNavigation(),
    openSettings: @escaping @MainActor () -> Void
  ) {
    self.model = model
    self.navigation = navigation
    self.openSettings = openSettings
    super.init()
  }

  public func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      model.accept(url: url)
    }
  }

  public func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    navigation.destination = .general
    openSettings()
    return true
  }
}

extension AppModel {
  static func production(
    navigation: SettingsNavigation,
    openSettings: @escaping @MainActor () -> Void
  ) -> AppModel {
    let applicationSupportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appending(path: "PickVia", directoryHint: .isDirectory)
    let configStore = JSONConfigStore(directory: applicationSupportDirectory)
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
      openBrowserSettings: recovery.open
    )
    let model = AppComposition.makeModel(
      configStore: configStore,
      browserCatalog: BrowserCatalog(),
      preferences: preferences,
      defaultBrowser: MacOSDefaultBrowserService(),
      loginItem: MacOSLoginItemService(),
      chooser: chooser,
      launcher: BrowserLauncher()
    )

    try? model.load()
    if model.browsers.isEmpty {
      try? model.rescan()
    }
    return model
  }
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
    launcher: any BrowserLaunching
  ) -> AppModel {
    let targetProvider = ConfigTargetProvider(configStore: configStore)
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
      routing: routing
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

private struct ConfigTargetProvider: TargetProviding, Sendable {
  let configStore: any ConfigStoring

  func availableSnapshot() -> RoutingTargetSnapshot {
    guard let config = try? configStore.load() else {
      return RoutingTargetSnapshot(applications: [], targets: [])
    }

    let applications = config.browsers.filter(\.isAvailable)
    let applicationIDs = Set(applications.map(\.id))
    let targets = config.targets
      .filter {
        $0.isEnabled
          && $0.availability == .available
          && applicationIDs.contains($0.browserID)
      }
      .sorted {
        if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
        return $0.id < $1.id
      }
    let targetBrowserIDs = Set(targets.map(\.browserID))
    return RoutingTargetSnapshot(
      applications: applications.filter { targetBrowserIDs.contains($0.id) },
      targets: targets
    )
  }
}
