import AppKit
import PickViaCore
import SwiftUI

func profileAccessStatusText(for state: BrowserProfileAccessRowState) -> String {
  switch state {
  case .accessNeeded:
    "Access needed"
  case .granted(let profileCount, _):
    "Granted — \(profileCount) \(profileCount == 1 ? "profile" : "profiles") found"
  case .invalidFolder:
    "Invalid folder"
  case .accessRevoked:
    "Access revoked"
  case .metadataDamaged:
    "Metadata damaged"
  }
}

func profileAccessPrimaryAction(
  for state: BrowserProfileAccessRowState,
  hasStoredGrant: Bool
) -> String? {
  switch state {
  case .accessNeeded, .invalidFolder, .accessRevoked:
    hasStoredGrant ? "Replace Access" : "Grant Access"
  case .granted, .metadataDamaged:
    nil
  }
}

func profileAccessCanFinish(rows: [BrowserProfileAccessRow]) -> Bool {
  rows.contains { row in
    switch row.state {
    case .granted:
      true
    case .invalidFolder:
      row.hasStoredGrant
    case .accessNeeded, .accessRevoked, .metadataDamaged:
      false
    }
  }
}

func profileAccessGuidanceText(
  for state: BrowserProfileAccessRowState,
  requiredMarker: String
) -> String? {
  switch state {
  case .accessNeeded, .invalidFolder, .accessRevoked:
    "Select the browser data folder containing \(requiredMarker)."
  case .granted(_, .currentSessionOnly):
    "Access is available until PickVia quits. To avoid granting it again, allow PickVia in Full Disk Access."
  case .granted(_, .persistent):
    nil
  case .metadataDamaged:
    "The browser profile metadata could not be read. Repair it in the browser, then rescan."
  }
}

public struct ProfileAccessWizardView: View {
  @Environment(AppModel.self) private var model

  let folderSelector: any ProfileAccessFolderSelecting
  let dismissWizard: @MainActor () -> Void

  public init(
    folderSelector: any ProfileAccessFolderSelecting,
    dismissWizard: @escaping @MainActor () -> Void
  ) {
    self.folderSelector = folderSelector
    self.dismissWizard = dismissWizard
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Browser Profile Access")
        .font(.largeTitle.bold())
      Text("Grant read-only access to each browser data folder so PickVia can find its profiles.")
        .foregroundStyle(.secondary)
      List(model.profileAccessRows) { row in
        ProfileAccessRowView(row: row, folderSelector: folderSelector)
      }
      HStack {
        Button("Skip for Now") {
          model.skipProfileAccess()
          dismissWizard()
        }
        Spacer()
        Button("Finish & Rescan") {
          do {
            try model.finishProfileAccessAndRescan()
            dismissWizard()
          } catch {
            model.reportProfileAccessCommitFailure()
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!profileAccessCanFinish(rows: model.profileAccessRows))
      }
    }
    .padding(24)
    .frame(width: 620, height: 440)
  }
}

private struct ProfileAccessRowView: View {
  @Environment(AppModel.self) private var model

  let row: BrowserProfileAccessRow
  let folderSelector: any ProfileAccessFolderSelecting

  @State private var showsRemoveConfirmation = false
  @State private var localErrorMessage: String?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      browserIcon
      VStack(alignment: .leading, spacing: 5) {
        Text(row.displayName)
          .font(.headline)
        Text(profileAccessStatusText(for: row.state))
          .foregroundStyle(statusColor)
        if let guidance = profileAccessGuidanceText(
          for: row.state,
          requiredMarker: row.requiredMarker
        ) {
          Text(guidance)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let localErrorMessage {
          Text(localErrorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      Spacer(minLength: 12)
      VStack(alignment: .trailing, spacing: 8) {
        if let action = profileAccessPrimaryAction(
          for: row.state,
          hasStoredGrant: row.hasStoredGrant
        ) {
          Button(action) {
            Task { await selectFolder() }
          }
        }
        if row.hasStoredGrant {
          Button("Remove Access", role: .destructive) {
            showsRemoveConfirmation = true
          }
        }
      }
    }
    .padding(.vertical, 6)
    .alert("Remove access for \(row.displayName)?", isPresented: $showsRemoveConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Remove Access", role: .destructive) { removeAccess() }
    } message: {
      Text("PickVia will stop using the saved browser folder grant and rescan its targets.")
    }
  }

  @ViewBuilder
  private var browserIcon: some View {
    if let applicationURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: row.bundleIdentifier
    ) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
        .resizable()
        .scaledToFit()
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    } else {
      Image(systemName: "globe")
        .font(.title2)
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
  }

  private var statusColor: Color {
    switch row.state {
    case .granted:
      .green
    case .accessNeeded, .invalidFolder, .accessRevoked, .metadataDamaged:
      .secondary
    }
  }

  private func selectFolder() async {
    guard
      let descriptor = BrowserDescriptor.descriptor(
        forBundleIdentifier: row.bundleIdentifier
      )
    else {
      localErrorMessage = "This browser is not supported for profile access."
      return
    }
    guard let root = await folderSelector.selectRoot(for: descriptor) else { return }
    do {
      try model.grantProfileAccess(for: row.bundleIdentifier, root: root)
      localErrorMessage = nil
    } catch {
      localErrorMessage = "PickVia could not save access to the selected browser folder."
    }
  }

  private func removeAccess() {
    do {
      try model.removeProfileAccess(for: row.bundleIdentifier)
      localErrorMessage = nil
    } catch {
      localErrorMessage = "PickVia could not remove the saved browser folder access."
    }
  }
}
