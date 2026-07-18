import AppKit

enum ChooserPanelLayout {
  static let contentWidth: CGFloat = 360
  static let gap: CGFloat = 10
  static let screenMargin: CGFloat = 12

  static func maximumPanelHeight(in visibleFrame: CGRect) -> CGFloat {
    max(1, visibleFrame.height - screenMargin * 2)
  }

  static func origin(
    pointer: CGPoint,
    panelSize: CGSize,
    visibleFrame: CGRect
  ) -> CGPoint {
    var x = pointer.x + gap
    var y = pointer.y - gap - panelSize.height
    if x + panelSize.width > visibleFrame.maxX - screenMargin {
      x = pointer.x - gap - panelSize.width
    }
    if y < visibleFrame.minY + screenMargin {
      y = pointer.y + gap
    }

    let minimumX = visibleFrame.minX + screenMargin
    let maximumX = max(minimumX, visibleFrame.maxX - screenMargin - panelSize.width)
    let minimumY = visibleFrame.minY + screenMargin
    let maximumY = max(minimumY, visibleFrame.maxY - screenMargin - panelSize.height)
    return CGPoint(
      x: min(max(x, minimumX), maximumX),
      y: min(max(y, minimumY), maximumY)
    )
  }
}
