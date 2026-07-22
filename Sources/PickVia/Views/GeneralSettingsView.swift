import SwiftUI

public struct GeneralSettingsView: View {
  @Environment(AppModel.self) private var model

  public init() {}

  public var body: some View {
    @Bindable var model = model
    Form {
      Section("Default browser") {
        DefaultStatusRows(status: model.defaultStatus)
        Button("Make PickVia Default Again") {
          Task { await model.requestDefaultBrowser() }
        }
        .disabled(!model.canRequestDefaultBrowser)
        Button("Refresh Status") {
          model.refreshDefaultStatus()
        }
      }

      Section("Behavior") {
        Toggle(
          "Launch PickVia at login",
          isOn: Binding(
            get: { model.launchesAtLogin },
            set: { model.setLaunchAtLogin($0) }
          ))
        Toggle("Show URL in browser chooser", isOn: $model.showsURLInChooser)
        Picker("Chooser size", selection: $model.chooserDensity) {
          ForEach(ChooserDensity.allCases) { density in
            Text(density.title).tag(density)
          }
        }
        .pickerStyle(.segmented)
      }

      if let errorMessage = model.errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("General")
  }
}
