import AppKit
import PickViaCore
import SwiftUI

public struct StatusMenuView: View {
  @AppStorage(L10n.preferenceKey) private var localizationSelection = L10n.system
  @Environment(AppModel.self) private var model
  @Environment(SettingsNavigation.self) private var navigation
  @Environment(\.profileAccessPresenter) private var profileAccessPresenter
  @Environment(\.openSettings) private var openSettings

  public init() {}

  private var settingsNavigationAction: SettingsNavigationAction {
    SettingsNavigationAction(
      model: model,
      navigation: navigation,
      openSettings: {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
      }
    )
  }

  private var aboutAction: AboutAction {
    AboutAction(
      model: model,
      showAboutPanel: {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
      }
    )
  }

  public var body: some View {
    let _ = localizationSelection
    #if PICKVIA_E2E_AUTOMATION
      if ProcessInfo.processInfo.environment["PICKVIA_E2E_MANUAL_UI"] == "1",
        let rawURL = ProcessInfo.processInfo.environment["PICKVIA_E2E_MANUAL_URL"],
        let url = URL(string: rawURL),
        url.scheme == "http", url.host == "127.0.0.1"
      {
        Button("Open Local E2E Test Page") {
          model.accept(
            url: url.appending(queryItems: [URLQueryItem(name: "request", value: UUID().uuidString)]
            )
          )
        }
      }
    #endif

    Button(L10n.tr("Open Settings…")) {
      settingsNavigationAction.open(.general)
    }
    .keyboardShortcut(",", modifiers: .command)
    .disabled(!settingsNavigationAction.isEnabled)

    Button(L10n.tr("Test Browser Chooser…")) {
      model.previewChooser(kind: .web)
    }
    .disabled(!model.canPresentOrdinaryAppSurface)

    Button(L10n.tr("Rescan Browsers")) {
      try? model.userRequestedRescan()
      profileAccessPresenter.requestIfPending(model: model)
    }
    .disabled(!model.canPresentOrdinaryAppSurface)

    Button(L10n.tr("Test Mail Chooser…")) {
      model.previewChooser(kind: .mail)
    }
    .disabled(!model.canPresentOrdinaryAppSurface)

    Button(L10n.tr("Rescan Mail Apps")) {
      try? model.rescanMailApplications()
    }
    .disabled(!model.canPresentOrdinaryAppSurface)

    Divider()

    Button(L10n.tr("About PickVia")) {
      aboutAction.show()
    }
    .disabled(!aboutAction.isEnabled)

    Divider()

    Button(L10n.tr("Quit PickVia")) {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q", modifiers: .command)
  }
}
