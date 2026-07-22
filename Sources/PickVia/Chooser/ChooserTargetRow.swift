import AppKit
import SwiftUI

struct ChooserTargetRow: View {
  let label: String
  let shortcut: ChooserShortcut?
  let applicationURL: URL?
  let isIndented: Bool
  let isSelected: Bool
  let metrics: ChooserMetrics
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if let applicationURL {
          applicationIcon(applicationURL)
        } else if isIndented {
          Color.clear.frame(width: 22, height: 1)
        }

        Text(label)
          .fontWeight(.medium)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer()
        if let shortcut {
          Text(shortcut.label)
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
      }
      .contentShape(Rectangle())
      .padding(.horizontal, metrics.rowHorizontalPadding)
      .padding(.vertical, metrics.rowVerticalPadding)
      .background(selectionFill, in: RoundedRectangle(cornerRadius: 7))
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .strokeBorder(
            isSelected ? Color.accentColor.opacity(0.55) : .clear,
            lineWidth: 1
          )
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  private var selectionFill: Color {
    if isSelected { return Color.accentColor.opacity(0.16) }
    if isHovering { return Color.accentColor.opacity(0.07) }
    return .clear
  }

  private func applicationIcon(_ url: URL) -> some View {
    let image = NSWorkspace.shared.icon(forFile: url.path)
    image.size = NSSize(width: 22, height: 22)
    return Image(nsImage: image).resizable().frame(width: 22, height: 22)
  }
}
