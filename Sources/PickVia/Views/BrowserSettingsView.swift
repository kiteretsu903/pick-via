import PickViaCore
import SwiftUI

public struct BrowserSettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.profileAccessPresenter) private var profileAccessPresenter
  @State private var showsAddTarget = false

  public init() {}

  public var body: some View {
    List {
      if let recoveryMessage = model.configurationRecoveryMessage {
        Section {
          Label(recoveryMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }
      ForEach(model.browsers) { browser in
        Section {
          let targets = targets(for: browser)
          if targets.isEmpty {
            Text(browser.isAvailable ? "No profiles discovered" : "Browser is missing")
              .foregroundStyle(.secondary)
          } else {
            ForEach(targets) { target in
              TargetSettingsRow(
                target: target,
                browser: browser,
                onRemove: target.origin == .manual
                  ? { try? model.removeManualTarget(id: target.id) } : nil
              )
            }
            .onMove { offsets, destination in
              move(browserTargets: targets, from: offsets, to: destination)
            }
          }
        } header: {
          HStack {
            Text(browser.displayName)
            if !browser.isAvailable { Text("Missing").foregroundStyle(.red) }
          }
        }
      }

      if model.browsers.isEmpty {
        ContentUnavailableView(
          "No Supported Browsers", systemImage: "globe.badge.chevron.backward",
          description: Text("Install a supported browser, then rescan."))
      }
    }
    .navigationTitle("Browsers")
    .toolbar {
      ToolbarItemGroup {
        Button("Add Target", systemImage: "plus") { showsAddTarget = true }
          .disabled(availableBrowsers.isEmpty)
        Button("Manage Profile Access…", systemImage: "folder.badge.key") {
          model.openProfileAccessManager()
          profileAccessPresenter.request(model: model)
        }
        Button("Rescan", systemImage: "arrow.clockwise") { rescan() }
      }
    }
    .sheet(isPresented: $showsAddTarget) {
      AddTargetView(browsers: availableBrowsers)
        .environment(model)
    }
    .onChange(of: showsAddTarget) { _, isPresented in
      if !isPresented {
        profileAccessPresenter.environmentDidChange()
      }
    }
  }

  private var availableBrowsers: [BrowserApplication] {
    model.browsers.filter { browser in
      browser.isAvailable
        && BrowserDescriptor.supported.contains {
          $0.bundleIdentifier == browser.bundleIdentifier && $0.family == browser.family
        }
    }
  }

  private func targets(for browser: BrowserApplication) -> [BrowserTarget] {
    model.targets.filter { $0.browserID == browser.id }.sorted {
      if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
      return $0.id < $1.id
    }
  }

  private func rescan() {
    try? model.userRequestedRescan()
    profileAccessPresenter.requestIfPending(model: model)
  }

  private func move(browserTargets: [BrowserTarget], from offsets: IndexSet, to destination: Int) {
    let all = model.targets.sorted {
      if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
      return $0.id < $1.id
    }
    let globalOffsets = IndexSet(
      offsets.compactMap { localIndex in
        all.firstIndex { $0.id == browserTargets[localIndex].id }
      })
    let globalDestination: Int
    if destination < browserTargets.count {
      globalDestination = all.firstIndex { $0.id == browserTargets[destination].id } ?? all.count
    } else {
      globalDestination =
        (browserTargets.last.flatMap { last in all.firstIndex { $0.id == last.id } } ?? all.count
          - 1) + 1
    }
    try? model.moveTargets(fromOffsets: globalOffsets, toOffset: globalDestination)
  }
}

private struct TargetSettingsRow: View {
  @Environment(AppModel.self) private var model
  let target: BrowserTarget
  let browser: BrowserApplication
  let onRemove: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Toggle(
          "",
          isOn: Binding(
            get: { target.isEnabled },
            set: { try? model.setTargetEnabled(id: target.id, isEnabled: $0) }
          )
        )
        .labelsHidden()
        TextField(
          "Label",
          text: Binding(
            get: { target.label },
            set: { try? model.renameTarget(id: target.id, label: $0) }
          ))
        if target.origin == .detected || browser.family == .safari {
          Text(target.profileDisplayName ?? "Default")
            .foregroundStyle(.secondary)
            .frame(width: 150, alignment: .leading)
        } else {
          Picker(
            "Profile",
            selection: Binding(
              get: { target.profileIdentity ?? target.profileIdentifier ?? "" },
              set: {
                try? model.setTargetProfile(
                  id: target.id,
                  profileIdentifier: $0.isEmpty ? nil : $0
                )
              }
            )
          ) {
            Text("Browser Default").tag("")
            ForEach(profileChoices) { profile in
              Text(profile.displayName).tag(profile.identifier)
            }
          }
          .frame(width: 150)
        }
        if target.origin == .detected {
          Text(target.mode == .private ? "Private" : "Normal")
            .foregroundStyle(.secondary)
            .frame(width: 130, alignment: .leading)
        } else {
          Picker(
            "Mode",
            selection: Binding(
              get: { target.mode },
              set: { try? model.setTargetMode(id: target.id, mode: $0) }
            )
          ) {
            Text("Normal").tag(BrowserMode.normal)
            if browser.family != .safari { Text("Private").tag(BrowserMode.private) }
          }
          .frame(width: 130)
        }
        if let onRemove {
          Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
            .labelStyle(.iconOnly)
        }
      }
      HStack(spacing: 8) {
        Text(target.profileDisplayName ?? "Default")
        if target.availability == .unavailable {
          Label("Profile missing", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        } else if !browser.isAvailable {
          Label("Browser missing", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private var profileChoices: [BrowserProfileChoice] {
    availableProfileChoices(browserID: browser.id, targets: model.targets)
  }
}

private struct AddTargetView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let browsers: [BrowserApplication]
  @State private var browserID: String = ""
  @State private var profileIdentifier: String = ""
  @State private var label = ""
  @State private var mode: BrowserMode = .normal
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Add Browser Target").font(.title2.bold())
      Form {
        Picker("Browser", selection: $browserID) {
          ForEach(browsers) { Text($0.displayName).tag($0.id) }
        }
        if selectedBrowser?.family != .safari {
          Picker("Profile", selection: $profileIdentifier) {
            Text("Browser Default").tag("")
            ForEach(profiles, id: \.identifier) { profile in
              Text(profile.displayName).tag(profile.identifier)
            }
          }
        }
        TextField("Label", text: $label)
        Picker("Mode", selection: $mode) {
          Text("Normal").tag(BrowserMode.normal)
          if selectedBrowser?.family != .safari { Text("Private").tag(BrowserMode.private) }
        }
      }
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
        Button("Add") { add() }
          .buttonStyle(.borderedProminent)
          .disabled(
            label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedBrowser == nil
          )
      }
    }
    .padding(24)
    .frame(width: 440)
    .onAppear { selectInitialValues() }
    .onChange(of: browserID) { selectInitialProfile() }
  }

  private var selectedBrowser: BrowserApplication? { browsers.first { $0.id == browserID } }

  private var profiles: [BrowserProfileChoice] {
    availableProfileChoices(browserID: browserID, targets: model.targets)
  }

  private func selectInitialValues() {
    if browserID.isEmpty { browserID = browsers.first?.id ?? "" }
    selectInitialProfile()
  }

  private func selectInitialProfile() {
    profileIdentifier = profiles.first?.identifier ?? ""
    if selectedBrowser?.family == .safari { mode = .normal }
    if label.isEmpty { label = selectedBrowser?.displayName ?? "" }
  }

  private func add() {
    do {
      try model.addManualTarget(
        browserID: browserID,
        profileIdentifier: selectedBrowser?.family == .safari || profileIdentifier.isEmpty
          ? nil
          : profileIdentifier,
        label: label,
        mode: mode
      )
      dismiss()
    } catch {
      errorMessage = "The target could not be added. Check the browser, profile, label, and mode."
    }
  }
}

struct BrowserProfileChoice: Equatable, Identifiable {
  let identifier: String
  let displayName: String

  var id: String { identifier }
}

func availableProfileChoices(
  browserID: BrowserApplication.ID,
  targets: [BrowserTarget]
) -> [BrowserProfileChoice] {
  var seen = Set<String>()
  return targets.compactMap { target in
    guard
      target.browserID == browserID,
      target.origin == .detected,
      target.availability == .available,
      let identifier = target.profileIdentity ?? target.profileIdentifier,
      seen.insert(identifier).inserted
    else { return nil }
    return BrowserProfileChoice(
      identifier: identifier,
      displayName: target.profileDisplayName ?? identifier
    )
  }
}
