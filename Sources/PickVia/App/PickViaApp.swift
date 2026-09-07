import PickViaCore
import SwiftUI

@main
struct PickViaApp: App {
  @AppStorage(L10n.preferenceKey) private var localizationSelection = L10n.system
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    let _ = localizationSelection
    MenuBarExtra {
      StatusMenuView()
        .pickViaLocalization()
        .environment(delegate.model)
        .environment(delegate.navigation)
        .environment(\.profileAccessPresenter, delegate.profileAccessPresenter)
    } label: {
      PickViaMenuBarLabel()
        .background {
          SettingsActionInstaller(opener: delegate.settingsSceneOpener)
        }
    }

    Settings {
      SettingsRootView()
        .pickViaLocalization()
        .environment(delegate.model)
        .environment(delegate.navigation)
        .environment(\.profileAccessPresenter, delegate.profileAccessPresenter)
    }
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button(L10n.tr("Settings…")) {
          delegate.settingsNavigationAction.open(.general)
        }
        .keyboardShortcut(",", modifiers: .command)
        .disabled(!delegate.settingsNavigationAction.isEnabled)
        #if PICKVIA_E2E_AUTOMATION
          if ProcessInfo.processInfo.environment["PICKVIA_E2E_MANUAL_UI"] == "1",
            let rawURL = ProcessInfo.processInfo.environment["PICKVIA_E2E_MANUAL_URL"],
            let url = URL(string: rawURL),
            url.scheme == "http", url.host == "127.0.0.1"
          {
            Button("Open Local E2E Test Page") {
              delegate.model.accept(
                url: url.appending(queryItems: [
                  URLQueryItem(name: "request", value: UUID().uuidString)
                ])
              )
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
          }
        #endif

      }

      CommandGroup(replacing: .appInfo) {
        Button(L10n.tr("About PickVia")) {
          delegate.aboutAction.show()
        }
        .disabled(!delegate.aboutAction.isEnabled)
      }
    }

    Window(L10n.tr("Welcome to PickVia"), id: "welcome") {
      WelcomeView()
        .pickViaLocalization()
        .environment(delegate.model)
        .environment(\.profileAccessPresenter, delegate.profileAccessPresenter)
    }
    .windowResizability(.contentSize)
  }
}
