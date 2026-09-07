import PickViaCore
import SwiftUI

public struct AboutView: View {
  @AppStorage(L10n.preferenceKey) private var localizationSelection = L10n.system
  public init() {}

  public var body: some View {
    let _ = localizationSelection
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? L10n.tr("Unknown")
    let build =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? L10n.tr("Unknown")

    VStack(spacing: 12) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 52))
        .foregroundStyle(.tint)
      Text("PickVia").font(.largeTitle.bold())
      Text(L10n.tr("Version {0} ({1})", version, build))
        .foregroundStyle(.secondary)
      Text(L10n.tr("Choose the right browser for every link."))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(L10n.tr("About"))
  }
}
