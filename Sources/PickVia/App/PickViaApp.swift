import SwiftUI

@main
struct PickViaApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    MenuBarExtra("PickVia", systemImage: "arrow.triangle.branch") {
      StatusMenuView()
        .environment(delegate.model)
    }

    Settings {
      SettingsRootView()
        .environment(delegate.model)
    }

    Window("Welcome to PickVia", id: "welcome") {
      WelcomeView()
        .environment(delegate.model)
    }
    .windowResizability(.contentSize)
  }
}
