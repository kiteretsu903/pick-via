import PickViaCore
import SwiftUI

@MainActor
final class SettingsSceneOpener {
  private var action: (@MainActor () -> Void)?
  private var hasPendingOpen = false

  func install(_ action: @escaping @MainActor () -> Void) {
    self.action = action
    guard hasPendingOpen else { return }
    hasPendingOpen = false
    action()
  }

  func open() {
    guard let action else {
      hasPendingOpen = true
      return
    }
    action()
  }
}

@MainActor
struct SettingsActionInstaller: View {
  @AppStorage(L10n.preferenceKey) private var localizationSelection = L10n.system
  @Environment(\.openSettings) private var openSettings

  let opener: SettingsSceneOpener

  var body: some View {
    let _ = localizationSelection
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear {
        let action = openSettings
        opener.install {
          action()
        }
      }
  }
}
