import AppKit
import PickViaCore
import SwiftUI

struct MailSettingsRow: Identifiable {
  let target: RouteTarget
  let application: RoutedApplication

  var id: RouteTarget.ID { target.id }
  var targetID: RouteTarget.ID { target.id }
  var isAvailable: Bool {
    target.availability == .available && application.isAvailable(for: .mail)
  }
}

func makeMailSettingsRows(
  applications: [RoutedApplication],
  targets: [RouteTarget]
) -> [MailSettingsRow] {
  let applicationsByID = Dictionary(uniqueKeysWithValues: applications.map { ($0.id, $0) })
  return targets
    .filter { $0.routeKind == .mail }
    .sorted {
      if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
      return $0.id < $1.id
    }
    .compactMap { target in
      applicationsByID[target.applicationID].map { MailSettingsRow(target: target, application: $0) }
    }
}

public struct MailSettingsView: View {
  @Environment(AppModel.self) private var model

  public init() {}

  public var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          Button(action: rescan) {
            Label("Rescan", systemImage: "arrow.clockwise")
          }
          Button("Make PickVia Default") {
            Task { await model.requestDefaultMail() }
          }
          Button("Refresh Status") {
            model.refreshDefaultStatus()
          }
          Spacer()
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)

        MailDefaultStatusRow(status: model.defaultStatus.mailto)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)

      Divider()

      List {
        if let errorMessage = model.mailErrorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }

        if model.mailApplications.isEmpty {
          ContentUnavailableView(
            "No Mail Applications",
            systemImage: "envelope.badge",
            description: Text("Install a mail application, then rescan."))
        } else {
          ForEach(rows) { row in
            MailTargetSettingsRow(row: row)
          }
          .onMove { offsets, destination in
            try? model.moveMailTargets(fromOffsets: offsets, toOffset: destination)
          }
        }
      }
    }
    .navigationTitle("Mail")
  }

  private var rows: [MailSettingsRow] {
    makeMailSettingsRows(applications: model.mailApplications, targets: model.mailTargets)
  }

  private func rescan() {
    try? model.rescanMailApplications()
  }
}

private struct MailDefaultStatusRow: View {
  let status: SchemeStatus

  var body: some View {
    HStack(spacing: 16) {
      Text("MAILTO").fontWeight(.medium)
      Label(
        statusText,
        systemImage: status == .isDefault ? "checkmark.circle.fill" : "exclamationmark.circle"
      )
      .foregroundStyle(status == .isDefault ? .green : .secondary)
      Spacer()
    }
    .font(.caption)
  }

  private var statusText: String {
    switch status {
    case .isDefault: "PickVia"
    case .notDefault: "Another app"
    case .unknown: "Unknown"
    }
  }
}

private struct MailTargetSettingsRow: View {
  @Environment(AppModel.self) private var model

  let row: MailSettingsRow

  var body: some View {
    HStack(spacing: 10) {
      applicationIcon
      Toggle(
        "",
        isOn: Binding(
          get: { row.target.isEnabled },
          set: { try? model.setMailTargetEnabled(id: row.targetID, isEnabled: $0) }
        )
      )
      .labelsHidden()
      TextField(
        "Label",
        text: Binding(
          get: { row.target.label },
          set: { try? model.renameTarget(id: row.targetID, label: $0) }
        )
      )
      if !row.isAvailable {
        Text("Missing").foregroundStyle(.red)
      }
    }
    .padding(.vertical, 4)
  }

  private var applicationIcon: some View {
    let image = NSWorkspace.shared.icon(forFile: row.application.applicationURL.path)
    image.size = NSSize(width: 22, height: 22)
    return Image(nsImage: image)
      .resizable()
      .frame(width: 22, height: 22)
  }
}
