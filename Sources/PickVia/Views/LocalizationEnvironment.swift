import PickViaCore
import SwiftUI

/// Applied at every hosting root, including independently hosted chooser panels.
struct LocalizationEnvironment: ViewModifier {
  @AppStorage(L10n.preferenceKey) private var language = L10n.system

  func body(content: Content) -> some View {
    let code = L10n.resolve(selection: language, preferredLanguages: Locale.preferredLanguages)
    content
      .background(LocalizationWindowClamp(selection: language).frame(width: 0, height: 0))
      .environment(\.locale, Locale(identifier: code))
      .environment(\.layoutDirection, L10n.isRightToLeft(code) ? .rightToLeft : .leftToRight)
  }
}

extension View {
  func pickViaLocalization() -> some View { modifier(LocalizationEnvironment()) }
}

/// SwiftUI can widen a native window after a translation changes. Keep that
/// window on its existing display rather than moving it to the pointer's screen.
private struct LocalizationWindowClamp: NSViewRepresentable {
  let selection: String

  func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

  func updateNSView(_ view: NSView, context: Context) {
    Task { @MainActor [weak view] in
      guard let window = view?.window, let screen = window.screen else { return }
      let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
      var frame = window.frame
      frame.size.width = min(frame.width, visible.width)
      frame.size.height = min(frame.height, visible.height)
      frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
      frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
      if frame != window.frame { window.setFrame(frame, display: true) }
    }
  }
}

@MainActor
enum LocalizationLayout {
  static var availableWidth: CGFloat {
    (NSApp?.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.width ?? 1200
  }

  static var availableHeight: CGFloat {
    (NSApp?.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
  }

  static var settingsWidth: CGFloat {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    let labels = ChooserDensity.allCases.map {
      ($0.title as NSString).size(withAttributes: [.font: font]).width + 34
    }
    return min(max(720, labels.reduce(0, +) + 310), availableWidth - 32)
  }
}
