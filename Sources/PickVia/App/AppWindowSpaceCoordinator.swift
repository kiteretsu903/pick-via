import AppKit

@MainActor
protocol AppWindowSpaceCoordinating: AnyObject {
  func prepareVisibleWindowsForActivation()
}

@MainActor
final class AppWindowSpaceCoordinator: AppWindowSpaceCoordinating {
  private let windowsProvider: @MainActor () -> [NSWindow]

  init(windowsProvider: @escaping @MainActor () -> [NSWindow] = { NSApp.windows }) {
    self.windowsProvider = windowsProvider
  }

  func prepareVisibleWindowsForActivation() {
    windowsProvider().forEach(applyPolicy)
  }

  private func applyPolicy(to window: NSWindow) {
    guard window.isVisible,
      !(window is NSPanel),
      !window.isSheet,
      window.level == .normal
    else {
      return
    }

    var collectionBehavior = window.collectionBehavior
    collectionBehavior.remove(.canJoinAllSpaces)
    collectionBehavior.insert(.moveToActiveSpace)
    window.collectionBehavior = collectionBehavior
  }
}
