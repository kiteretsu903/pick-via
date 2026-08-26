import PickViaCore
import SwiftUI

public struct BrowserSettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.profileAccessPresenter) private var profileAccessPresenter
  @State private var showsAddTarget = false

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Button {
            showsAddTarget = true
          } label: {
            Label("Add Target", systemImage: "plus")
          }
          .disabled(availableBrowsers.isEmpty)

          Button {
            model.openProfileAccessManager()
            profileAccessPresenter.request(model: model)
          } label: {
            HStack(spacing: 6) {
              Label("Profile Access", systemImage: "folder.badge.key")
              issueDots(model.browserSettingsIssueSummary)
            }
          }
          .help(profileAccessAccessibilityText(model.browserSettingsIssueSummary))
          .accessibilityLabel(profileAccessAccessibilityText(model.browserSettingsIssueSummary))

          Button(action: rescan) {
            Label("Rescan", systemImage: "arrow.clockwise")
          }
          Spacer()
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)

        let segments = model.browserSettingsIssueSummary.segments
        if !segments.isEmpty {
          HStack(spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { entry in
              if entry.offset > 0 { Text("·").foregroundStyle(.secondary) }
              let segment = entry.element
              Label(segment.text, systemImage: issueSymbol(segment.kind))
                .foregroundStyle(issueColor(segment.kind))
            }
            Spacer()
          }
          .font(.caption)
          .accessibilityElement(children: .combine)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      Divider()

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
    }
    .navigationTitle("Browsers")
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

  @ViewBuilder
  private func issueDots(_ summary: BrowserSettingsIssueSummary) -> some View {
    HStack(spacing: 3) {
      ForEach(summary.segments) { segment in
        Circle()
          .fill(issueColor(segment.kind))
          .frame(width: 7, height: 7)
          .accessibilityHidden(true)
      }
    }
  }

  private func issueSymbol(_ kind: BrowserSettingsIssueKind) -> String {
    switch kind {
    case .access: "exclamationmark.triangle.fill"
    case .missingProfile: "circle.fill"
    }
  }

  private func issueColor(_ kind: BrowserSettingsIssueKind) -> Color {
    switch kind {
    case .access: .orange
    case .missingProfile: .red
    }
  }

  private func profileAccessAccessibilityText(
    _ summary: BrowserSettingsIssueSummary
  ) -> String {
    let details = summary.segments.map(\.text).joined(separator: ", ")
    return details.isEmpty ? "Profile Access" : "Profile Access, \(details)"
  }

  private var availableBrowsers: [BrowserApplication] {
    availableBrowsersForManualTargets(model.browsers)
  }

  private func targets(for browser: BrowserApplication) -> [BrowserTarget] {
    browserSettingsTargets(browserID: browser.id, targets: model.targets)
  }

  private func rescan() {
    try? model.userRequestedRescan()
    profileAccessPresenter.requestIfPending(model: model)
  }

  private func move(browserTargets: [BrowserTarget], from offsets: IndexSet, to destination: Int) {
    let all = model.targets.filter { $0.routeKind == .web }.sorted {
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
        .disabled(!capabilities.supportsRoute(hasProfile: hasProfile, mode: target.mode))
        TextField(
          "Label",
          text: Binding(
            get: { target.label },
            set: { try? model.renameTarget(id: target.id, label: $0) }
          ))
        if target.origin == .detected || !canEditProfile {
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
            if capabilities.supportsRoute(hasProfile: false, mode: target.mode) {
              Text("Browser Default").tag("")
            }
            if capabilities.supportsRoute(hasProfile: true, mode: target.mode) {
              ForEach(profileChoices) { profile in
                Text(profile.displayName).tag(profile.identifier)
              }
            }
          }
          .frame(width: 150)
        }
        if target.origin == .detected
          || !shouldShowBrowserModePicker(
            capabilities: capabilities,
            hasProfile: hasProfile,
            currentMode: target.mode
          )
        {
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
            ForEach(availableModes, id: \.rawValue) { mode in
              Text(mode == .private ? "Private" : "Normal").tag(mode)
            }
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

  private var capabilities: BrowserTargetCapabilities {
    browserTargetCapabilities(for: browser, targets: model.targets)
  }

  private var hasProfile: Bool {
    target.profileIdentifier != nil
      || target.profileDisplayName != nil
      || target.profileIdentity != nil
      || target.profileLaunchPath != nil
  }

  private var availableModes: [BrowserMode] {
    browserModes(capabilities: capabilities, hasProfile: hasProfile)
  }

  private var canEditProfile: Bool {
    shouldShowBrowserProfilePicker(
      capabilities: capabilities,
      hasProfile: hasProfile,
      mode: target.mode,
      profileCount: profileChoices.count
    )
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
        if selectedCapabilities.supportsRoute(hasProfile: false, mode: mode)
          || selectedCapabilities.supportsRoute(hasProfile: true, mode: mode)
        {
          Picker("Profile", selection: $profileIdentifier) {
            if selectedCapabilities.supportsRoute(hasProfile: false, mode: mode) {
              Text("Browser Default").tag("")
            }
            if selectedCapabilities.supportsRoute(hasProfile: true, mode: mode) {
              ForEach(profiles, id: \.identifier) { profile in
                Text(profile.displayName).tag(profile.identifier)
              }
            }
          }
        }
        TextField("Label", text: $label)
        Picker("Mode", selection: $mode) {
          ForEach(selectedModes, id: \.rawValue) { mode in
            Text(mode == .private ? "Private" : "Normal").tag(mode)
          }
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
              || selectedModes.isEmpty
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

  private var selectedCapabilities: BrowserTargetCapabilities {
    guard let selectedBrowser else { return .unavailable }
    return browserTargetCapabilities(for: selectedBrowser, targets: model.targets)
  }

  private var selectedModes: [BrowserMode] {
    browserModes(
      capabilities: selectedCapabilities,
      hasProfile: !profileIdentifier.isEmpty
    )
  }

  private func selectInitialValues() {
    if browserID.isEmpty { browserID = browsers.first?.id ?? "" }
    selectInitialProfile()
  }

  private func selectInitialProfile() {
    let firstProfile = profiles.first?.identifier
    let candidates: [(String?, BrowserMode)] = [
      (firstProfile, .normal),
      (nil, .normal),
      (firstProfile, .private),
      (nil, .private),
    ]
    if let selection = candidates.first(where: { profile, mode in
      selectedCapabilities.supportsRoute(
        hasProfile: profile != nil,
        mode: mode
      )
    }) {
      profileIdentifier = selection.0 ?? ""
      mode = selection.1
    } else {
      profileIdentifier = ""
      mode = .normal
    }
    if label.isEmpty { label = selectedBrowser?.displayName ?? "" }
  }

  private func add() {
    do {
      try model.addManualTarget(
        browserID: browserID,
        profileIdentifier: profileIdentifier.isEmpty ? nil : profileIdentifier,
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

struct BrowserTargetCapabilities: Equatable {
  let descriptor: BrowserDescriptor?
  let hasDetectedProfiles: Bool
  let browserPrivateModeIsAvailable: Bool

  static let unavailable = BrowserTargetCapabilities(
    descriptor: nil,
    hasDetectedProfiles: false,
    browserPrivateModeIsAvailable: false
  )

  func supportsRoute(hasProfile: Bool, mode: BrowserMode) -> Bool {
    guard
      let descriptor,
      descriptor.supportsRoute(hasProfile: hasProfile, mode: mode)
    else { return false }
    if hasProfile, !hasDetectedProfiles { return false }
    if !hasProfile, mode == .private { return browserPrivateModeIsAvailable }
    return true
  }
}

func browserModes(
  capabilities: BrowserTargetCapabilities,
  hasProfile: Bool
) -> [BrowserMode] {
  [BrowserMode.normal, .private].filter {
    capabilities.supportsRoute(hasProfile: hasProfile, mode: $0)
  }
}

func shouldShowBrowserModePicker(
  capabilities: BrowserTargetCapabilities,
  hasProfile: Bool,
  currentMode: BrowserMode
) -> Bool {
  let modes = browserModes(capabilities: capabilities, hasProfile: hasProfile)
  return modes.count > 1 || (!modes.isEmpty && !modes.contains(currentMode))
}

func shouldShowBrowserProfilePicker(
  capabilities: BrowserTargetCapabilities,
  hasProfile: Bool,
  mode: BrowserMode,
  profileCount: Int
) -> Bool {
  let supportsDefault = capabilities.supportsRoute(hasProfile: false, mode: mode)
  let supportedProfileCount =
    capabilities.supportsRoute(hasProfile: true, mode: mode)
    ? profileCount : 0
  let optionCount = (supportsDefault ? 1 : 0) + supportedProfileCount
  let currentRouteIsSupported = capabilities.supportsRoute(
    hasProfile: hasProfile,
    mode: mode
  )
  return optionCount > 1 || (optionCount > 0 && !currentRouteIsSupported)
}

func availableBrowsersForManualTargets(
  _ browsers: [BrowserApplication]
) -> [BrowserApplication] {
  browsers.filter { browser in
    browser.isAvailable
      && BrowserDescriptor.descriptor(forBundleIdentifier: browser.bundleIdentifier) != nil
  }
}

func browserTargetCapabilities(
  for browser: BrowserApplication,
  targets: [BrowserTarget]
) -> BrowserTargetCapabilities {
  guard
    let descriptor = BrowserDescriptor.descriptor(
      forBundleIdentifier: browser.bundleIdentifier
    )
  else { return .unavailable }
  return browserTargetCapabilities(
    for: browser,
    descriptor: descriptor,
    targets: targets
  )
}

func browserTargetCapabilities(
  for browser: BrowserApplication,
  descriptor: BrowserDescriptor,
  targets: [BrowserTarget]
) -> BrowserTargetCapabilities {
  let detectedAvailableTargets = targets.filter {
    $0.routeKind == .web
      && $0.applicationID == browser.id
      && $0.origin == .detected
      && $0.availability == .available
  }
  return BrowserTargetCapabilities(
    descriptor: descriptor,
    hasDetectedProfiles: detectedAvailableTargets.contains {
      $0.profileIdentity != nil || $0.profileIdentifier != nil
    },
    browserPrivateModeIsAvailable: BrowserPrivateCapabilityResolver.isAvailable(
      descriptor: descriptor,
      applicationID: browser.id,
      targets: targets
    )
  )
}

func availableProfileChoices(
  browserID: BrowserApplication.ID,
  targets: [BrowserTarget]
) -> [BrowserProfileChoice] {
  var seen = Set<String>()
  return targets.compactMap { target in
    guard
      target.routeKind == .web,
      target.applicationID == browserID,
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

func browserSettingsTargets(
  browserID: BrowserApplication.ID,
  targets: [BrowserTarget]
) -> [BrowserTarget] {
  targets.filter {
    $0.routeKind == .web && $0.applicationID == browserID
  }.sorted {
    if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
    return $0.id < $1.id
  }
}
