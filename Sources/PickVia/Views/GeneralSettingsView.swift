import PickViaCore
import SwiftUI

public struct GeneralSettingsView: View {
  @AppStorage(L10n.preferenceKey) private var localizationSelection = L10n.system
  @Environment(AppModel.self) private var model

  public init() {}

  public var body: some View {
    let _ = localizationSelection
    @Bindable var model = model
    Form {
      Section(L10n.tr("Language")) {
        Picker(L10n.tr("Language"), selection: $localizationSelection) {
          Text(L10n.tr("System Default")).tag(L10n.system)
          ForEach(L10n.languages) { language in
            Text(verbatim: language.name).tag(language.code)
          }
        }
        .accessibilityIdentifier("app-language-picker")
      }
      Section(L10n.tr("Default browser")) {
        BrowserDefaultStatusRows(status: model.defaultStatus)
        Button(L10n.tr("Make PickVia Default Again")) {
          Task { await model.requestDefaultBrowser() }
        }
        .disabled(!model.canRequestDefaultBrowser)
        Button(L10n.tr("Refresh Status")) {
          model.refreshDefaultStatus()
        }
      }

      Section(L10n.tr("Behavior")) {
        Toggle(
          L10n.tr("Launch PickVia at login"),
          isOn: Binding(
            get: { model.launchesAtLogin },
            set: { model.setLaunchAtLogin($0) }
          ))
        Toggle(L10n.tr("Show URL in browser chooser"), isOn: $model.showsURLInChooser)
        Picker(L10n.tr("Chooser size"), selection: $model.chooserDensity) {
          ForEach(ChooserDensity.allCases) { density in
            Text(density.title).tag(density)
          }
        }
        .pickerStyle(.segmented)
      }

      if let errorMessage = model.errorMessage {
        Section {
          Label(L10n.tr(errorMessage), systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(L10n.tr("General"))
  }
}
