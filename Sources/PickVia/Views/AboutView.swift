import SwiftUI

public struct AboutView: View {
  public init() {}

  public var body: some View {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"

    VStack(spacing: 12) {
      Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 52))
        .foregroundStyle(.tint)
      Text("PickVia").font(.largeTitle.bold())
      Text("Version \(version) (\(build))")
        .foregroundStyle(.secondary)
      Text("Choose the right browser for every link.")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle("About")
  }
}
