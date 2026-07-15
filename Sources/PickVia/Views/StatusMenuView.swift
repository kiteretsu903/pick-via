import AppKit
import SwiftUI

public struct StatusMenuView: View {
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

  public var body: some View {
    Button("Open Settings…") {
      settingsNavigationAction.open(.general)
    }
    .keyboardShortcut(",", modifiers: .command)
    .disabled(!settingsNavigationAction.isEnabled)

    Button("Test Browser Chooser…") {
      model.previewChooser()
    }
    .disabled(!model.canPresentOrdinaryAppSurface)

    Button("Rescan Browsers") {
      try? model.userRequestedRescan()
      profileAccessPresenter.requestIfPending(model: model)
    }
    .disabled(!model.canPresentOrdinaryAppSurface)

    Divider()

    Button("About PickVia") {
      showAboutIfAllowed(model: model) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
      }
    }
    .disabled(!model.canPresentOrdinaryAppSurface)

    Divider()

    Button("Quit PickVia") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q", modifiers: .command)
  }
}

@MainActor
func showAboutIfAllowed(
  model: AppModel,
  showAbout: @MainActor () -> Void
) {
  guard model.canPresentOrdinaryAppSurface else { return }
  showAbout()
}
