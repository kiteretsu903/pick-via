import AppKit
import Foundation
import PickViaCore

public enum ChooserDensity: Int, CaseIterable, Identifiable, Sendable {
  case compact = 0
  case balanced = 1
  case spacious = 2

  public var id: Int { rawValue }

  public var title: String {
    switch self {
    case .compact: L10n.tr("Compact")
    case .balanced: L10n.tr("Balanced")
    case .spacious: L10n.tr("Spacious")
    }
  }

  public static func fromPersistedValue(_ value: Int?) -> ChooserDensity {
    value.flatMap(ChooserDensity.init(rawValue:)) ?? .compact
  }

  var metrics: ChooserMetrics {
    switch self {
    case .compact:
      ChooserMetrics(
        contentWidth: 340, outerPadding: 12, mainSpacing: 8,
        groupSpacing: 3, rowHorizontalPadding: 8, rowVerticalPadding: 3,
        headerHorizontalPadding: 8, headerVerticalPadding: 1
      )
    case .balanced:
      ChooserMetrics(
        contentWidth: 380, outerPadding: 14, mainSpacing: 10,
        groupSpacing: 6, rowHorizontalPadding: 10, rowVerticalPadding: 5,
        headerHorizontalPadding: 10, headerVerticalPadding: 2
      )
    case .spacious:
      ChooserMetrics(
        contentWidth: 420, outerPadding: 18, mainSpacing: 14,
        groupSpacing: 9, rowHorizontalPadding: 12, rowVerticalPadding: 8,
        headerHorizontalPadding: 12, headerVerticalPadding: 4
      )
    }
  }
}

struct ChooserMetrics: Equatable, Sendable {
  let contentWidth: CGFloat
  let outerPadding: CGFloat
  let mainSpacing: CGFloat
  let groupSpacing: CGFloat
  let rowHorizontalPadding: CGFloat
  let rowVerticalPadding: CGFloat
  let headerHorizontalPadding: CGFloat
  let headerVerticalPadding: CGFloat
}

@MainActor
extension ChooserDensity {
  var localizedContentWidth: CGFloat {
    let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    let labels = ["Copy", "Settings", "Cancel"].map {
      (L10n.tr($0) as NSString).size(withAttributes: [.font: font]).width + 24
    }
    return min(
      max(metrics.contentWidth, labels.reduce(0, +) + 70), LocalizationLayout.availableWidth - 32)
  }
}
