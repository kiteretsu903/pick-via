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

    Divider()

    Button("About PickVia") {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.orderFrontStandardAboutPanel(nil)
    }

    Divider()

    Button("Quit PickVia") {
      NSApp.terminate(nil)
    }
    .keyboardShortcut("q", modifiers: .command)
  }
}
