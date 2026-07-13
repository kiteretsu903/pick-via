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
  @State private var selection: SettingsDestination? = .general

  public init() {}

  public var body: some View {
    NavigationSplitView {
      List(SettingsDestination.allCases, selection: $selection) { destination in
        Label(destination.title, systemImage: destination.systemImage)
          .tag(Optional(destination))
      }
      .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    } detail: {
      switch selection ?? .general {
      case .general: GeneralSettingsView()
      case .browsers: BrowserSettingsView()
      case .about: AboutView()
      }
    }
    .environment(model)
    .frame(minWidth: 720, minHeight: 480)
  }
}
