import AppKit
import SwiftUI

public struct StatusMenuView: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsNavigation.self) private var navigation
  @Environment(\.profileAccessPresenter) private var profileAccessPresenter
  @Environment(\.openSettings) private var openSettings

  public init() {}

  public var body: some View {
    Button("Open Settings…") {
      guard model.canPresentOrdinaryAppSurface else { return }
      navigation.destination = .general
      NSApp.activate(ignoringOtherApps: true)
      openSettings()
    }
    .keyboardShortcut(",", modifiers: .command)
    .disabled(!model.canPresentOrdinaryAppSurface)

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
