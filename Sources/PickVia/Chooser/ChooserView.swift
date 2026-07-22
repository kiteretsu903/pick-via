import AppKit
import PickViaCore
import SwiftUI

public struct ChooserView: View {
  public let presentation: ChooserPresentation
  public let showsURL: Bool
  public let density: ChooserDensity
  public let maximumContentHeight: CGFloat?
  public let onSelection: (BrowserTarget.ID) -> Void
  public let onCopyURL: () -> Void
  public let onOpenBrowserSettings: () -> Void
  public let onCancel: () -> Void

  public init(
    presentation: ChooserPresentation,
    showsURL: Bool = true,
    density: ChooserDensity = .compact,
    maximumContentHeight: CGFloat? = nil,
    onSelection: @escaping (BrowserTarget.ID) -> Void,
    onCopyURL: @escaping () -> Void,
    onOpenBrowserSettings: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.presentation = presentation
    self.showsURL = showsURL
    self.density = density
    self.maximumContentHeight = maximumContentHeight
    self.onSelection = onSelection
    self.onCopyURL = onCopyURL
    self.onOpenBrowserSettings = onOpenBrowserSettings
    self.onCancel = onCancel
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Open link with")
        .font(.title2.weight(.semibold))

      if showsURL {
        Text(presentation.displayURL)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }

      if let errorMessage = presentation.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      if presentation.rows.isEmpty {
        Text("No available browser targets. Open Browser Settings to add or enable one.")
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        ViewThatFits(in: .vertical) {
          groupStack.fixedSize(horizontal: false, vertical: true)
          ScrollViewReader { proxy in
            ScrollView(.vertical) {
              groupStack
            }
            .task(id: selectedTargetID) {
              if let selectedTargetID {
                proxy.scrollTo(selectedTargetID, anchor: .center)
              }
            }
          }
        }
      }

      Divider()

      HStack {
        Button("Copy", systemImage: "doc.on.doc", action: onCopyURL)
        Button("Settings", systemImage: "gearshape", action: onOpenBrowserSettings)
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
      }
      .controlSize(.small)
    }
    .padding(14)
    .frame(width: density.metrics.contentWidth)
    .frame(maxHeight: maximumContentHeight)
    .background(.regularMaterial)
  }

  private var selectedTargetID: BrowserTarget.ID? {
    guard let selectedIndex = presentation.selectedIndex,
      presentation.rows.indices.contains(selectedIndex)
    else { return nil }
    return presentation.rows[selectedIndex].targetID
  }

  private var groupStack: some View {
    VStack(spacing: 6) {
      ForEach(presentation.groups) { group in
        groupView(group)
      }
    }
  }

  @ViewBuilder
  private func groupView(_ group: ChooserGroup) -> some View {
    switch group {
    case .direct(_, let row):
      rowView(row, indented: false)
        .id(row.targetID)
    case .group(let browserID, let rows):
      if let application = presentation.application(for: browserID) {
        HStack(spacing: 8) {
          applicationIcon(application)
          Text(application.displayName)
            .font(.headline)
          Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 2)
      }
      ForEach(rows) { row in
        rowView(row, indented: true)
          .id(row.targetID)
      }
    }
  }

  @ViewBuilder
  private func rowView(_ row: ChooserRow, indented: Bool) -> some View {
    if let target = presentation.target(for: row),
      let application = presentation.application(for: target.browserID)
    {
      let selected =
        presentation.selectedIndex.flatMap {
          presentation.rows.indices.contains($0) ? presentation.rows[$0].id : nil
        } == row.id

      Button {
        onSelection(row.targetID)
      } label: {
        HStack(spacing: 10) {
          if !indented {
            applicationIcon(application)
          } else {
            Color.clear.frame(width: 22, height: 1)
          }
          VStack(alignment: .leading, spacing: 1) {
            Text(target.label)
              .fontWeight(.medium)
              .lineLimit(1)
              .truncationMode(.tail)
            Text(detail(for: target, application: application, indented: indented))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
          Spacer()
          if let shortcut = row.shortcut {
            Text(shortcut.label)
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
          }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
          selected ? Color.accentColor.opacity(0.2) : Color.clear,
          in: RoundedRectangle(cornerRadius: 8)
        )
      }
      .buttonStyle(.plain)
    }
  }

  private func applicationIcon(_ application: BrowserApplication) -> some View {
    let image = NSWorkspace.shared.icon(forFile: application.applicationURL.path)
    image.size = NSSize(width: 22, height: 22)
    return Image(nsImage: image)
      .resizable()
      .frame(width: 22, height: 22)
  }

  private func detail(
    for target: BrowserTarget,
    application: BrowserApplication,
    indented: Bool
  ) -> String {
    var parts: [String] = []
    if !indented { parts.append(application.displayName) }
    if let profile = target.profileDisplayName, profile != target.label {
      parts.append(profile)
    }
    if target.mode == .private { parts.append("Private") }
    return parts.isEmpty
      ? (target.mode == .private ? "Private" : "Normal") : parts.joined(separator: " · ")
  }
}
