import AppKit
import Foundation
import PickViaCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
  public let model: AppModel

  private let openSettings: @MainActor () -> Void

  public override convenience init() {
    let openSettings: @MainActor () -> Void = {
      NSApp.activate(ignoringOtherApps: true)
      _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    self.init(
      model: AppModel.production(openBrowserSettings: openSettings),
      openSettings: openSettings
    )
  }

  init(
    model: AppModel,
    openSettings: @escaping @MainActor () -> Void
  ) {
    self.model = model
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
    openSettings()
    return true
  }
}

extension AppModel {
  static func production(
    openBrowserSettings: @escaping @MainActor () -> Void
  ) -> AppModel {
    let applicationSupportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0].appending(path: "PickVia", directoryHint: .isDirectory)
    let configStore = JSONConfigStore(directory: applicationSupportDirectory)
    let chooser = ChooserPanelController(
      clipboard: SystemClipboardWriter(),
      openBrowserSettings: openBrowserSettings
    )
    let coordinator = RoutingCoordinator(
      targetProvider: ConfigTargetProvider(configStore: configStore),
      chooser: chooser,
      launcher: BrowserLauncher()
    )
    let routing = RoutingCoordinatorAdapter(
      coordinator: coordinator,
      previewAction: { [weak coordinator] url in
        coordinator?.enqueue(url)
      }
    )
    let model = AppModel(
      configStore: configStore,
      browserCatalog: BrowserCatalog(),
      preferences: UserDefaultsPreferences(),
      defaultBrowser: MacOSDefaultBrowserService(),
      loginItem: MacOSLoginItemService(),
      routing: routing
    )

    try? model.load()
    if model.browsers.isEmpty {
      try? model.rescan()
    }
    return model
  }
}

private struct ConfigTargetProvider: TargetProviding, Sendable {
  let configStore: JSONConfigStore

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
