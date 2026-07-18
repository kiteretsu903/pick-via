import AppKit
import SwiftUI

enum PickViaMenuBarIcon {
  static let fallbackSystemName = "arrow.triangle.branch"

  static func load(bundle: Bundle = .main) -> NSImage? {
    load(from: bundle.url(forResource: "PickViaMenuBarTemplate", withExtension: "png"))
  }

  static func load(from url: URL?) -> NSImage? {
    guard let url, let image = NSImage(contentsOf: url) else { return nil }
    image.size = NSSize(width: 22, height: 22)
    image.isTemplate = true
    return image
  }
}

struct PickViaMenuBarLabel: View {
  private let image: NSImage?

  init(bundle: Bundle = .main) {
    image = PickViaMenuBarIcon.load(bundle: bundle)
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
      } else {
        Image(systemName: PickViaMenuBarIcon.fallbackSystemName)
      }
    }
    .accessibilityLabel("PickVia")
  }
}
