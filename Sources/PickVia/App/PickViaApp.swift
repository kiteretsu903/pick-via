import SwiftUI

@main
struct PickViaApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    MenuBarExtra("PickVia", systemImage: "arrow.triangle.branch") {
      StatusMenuView()
        .environment(delegate.model)
        .environment(delegate.navigation)
        .environment(\.profileAccessPresenter, delegate.profileAccessPresenter)
    }

    Settings {
      SettingsRootView()
        .environment(delegate.model)
        .environment(delegate.navigation)
        .environment(\.profileAccessPresenter, delegate.profileAccessPresenter)
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") {
          delegate.settingsNavigationAction.open(.general)
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(!delegate.settingsNavigationAction.isEnabled)
      }
    }

    Window("Welcome to PickVia", id: "welcome") {
      WelcomeView()
        .environment(delegate.model)
        .environment(\.profileAccessPresenter, delegate.profileAccessPresenter)
    }
    .windowResizability(.contentSize)
  }
}
