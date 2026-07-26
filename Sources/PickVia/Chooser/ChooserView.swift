import AppKit
import PickViaCore
import SwiftUI

public struct ChooserView: View {
  public let presentation: ChooserPresentation
  public let showsURL: Bool
  public let density: ChooserDensity
  public let maximumContentHeight: CGFloat?
  public let onSelection: (RouteTarget.ID) -> Void
  public let onCopyURL: () -> Void
  public let onOpenSettings: (RouteKind) -> Void
  public let onCancel: () -> Void

  public init(
    presentation: ChooserPresentation,
    showsURL: Bool = true,
    density: ChooserDensity = .compact,
    maximumContentHeight: CGFloat? = nil,
    onSelection: @escaping (RouteTarget.ID) -> Void,
    onCopyURL: @escaping () -> Void,
    onOpenSettings: @escaping (RouteKind) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.presentation = presentation
    self.showsURL = showsURL
    self.density = density
    self.maximumContentHeight = maximumContentHeight
    self.onSelection = onSelection
    self.onCopyURL = onCopyURL
    self.onOpenSettings = onOpenSettings
    self.onCancel = onCancel
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: metrics.mainSpacing) {
      Text(presentation.heading)
        .font(.title2.weight(.semibold))

      if presentation.kind == .web, showsURL, let displayURL = presentation.displayURL {
        Text(displayURL)
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
        Text(presentation.emptyStateMessage)
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
        if presentation.showsCopyAction {
          Button("Copy", systemImage: "doc.on.doc", action: onCopyURL)
        }
        Button("Settings", systemImage: "gearshape") {
          onOpenSettings(presentation.kind)
        }
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
      }
      .controlSize(.small)
    }
    .padding(metrics.outerPadding)
    .frame(width: density.metrics.contentWidth)
    .frame(maxHeight: maximumContentHeight)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  private var metrics: ChooserMetrics { density.metrics }

  private var selectedTargetID: RouteTarget.ID? {
    guard let selectedIndex = presentation.selectedIndex,
      presentation.rows.indices.contains(selectedIndex)
    else { return nil }
    return presentation.rows[selectedIndex].targetID
  }

  private var groupStack: some View {
    VStack(spacing: metrics.groupSpacing) {
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
    case .group(let applicationID, let rows):
      if let application = presentation.application(for: applicationID) {
        HStack(spacing: 8) {
          applicationIcon(application)
          Text(application.displayName)
            .font(.headline)
          Spacer()
        }
        .padding(.horizontal, metrics.headerHorizontalPadding)
        .padding(.vertical, metrics.headerVerticalPadding)
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
      let application = presentation.application(for: target.applicationID)
    {
      let selected =
        presentation.selectedIndex.flatMap {
          presentation.rows.indices.contains($0) ? presentation.rows[$0].id : nil
        } == row.id

      ChooserTargetRow(
        label: target.label,
        shortcut: row.shortcut,
        applicationURL: indented ? nil : application.applicationURL,
        isIndented: indented,
        isSelected: selected,
        metrics: metrics,
        action: { onSelection(row.targetID) }
      )
    }
  }

  private func applicationIcon(_ application: RoutedApplication) -> some View {
    let image = NSWorkspace.shared.icon(forFile: application.applicationURL.path)
    image.size = NSSize(width: 22, height: 22)
    return Image(nsImage: image)
      .resizable()
      .frame(width: 22, height: 22)
  }
}
