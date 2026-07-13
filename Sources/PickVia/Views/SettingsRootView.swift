import SwiftUI

public enum SettingsDestination: String, CaseIterable, Identifiable {
  case general
  case browsers
  case about

  public var id: Self { self }
  public var title: String { rawValue.capitalized }

  public var systemImage: String {
    switch self {
    case .general: "gear"
    case .browsers: "globe"
    case .about: "info.circle"
    }
  }
}

public struct SettingsRootView: View {
  @Environment(AppModel.self) private var model
  @Environment(SettingsNavigation.self) private var navigation
  @Environment(\.profileAccessPresenter) private var profileAccessPresenter

  public init() {}

  public var body: some View {
    @Bindable var navigation = navigation
    NavigationSplitView {
      List(SettingsDestination.allCases, selection: $navigation.destination) { destination in
        Label(destination.title, systemImage: destination.systemImage)
          .tag(destination)
      }
      .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    } detail: {
      switch navigation.destination {
      case .general: GeneralSettingsView()
      case .browsers: BrowserSettingsView()
      case .about: AboutView()
      }
    }
    .environment(model)
    .frame(minWidth: 720, minHeight: 480)
    .onDisappear {
      settingsDidClose(
        model: model,
        profileAccessPresenter: profileAccessPresenter
      )
    }
  }
}

@MainActor
func settingsDidClose(
  model: AppModel,
  profileAccessPresenter: any ProfileAccessPresenting
) {
  model.settingsDidClose()
  profileAccessPresenter.requestIfPending(model: model)
}
