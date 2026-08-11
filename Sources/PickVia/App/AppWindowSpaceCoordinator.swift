import AppKit

@MainActor
protocol AppWindowSpaceCoordinating: AnyObject {
  func prepareVisibleWindowsForActivation()
}

@MainActor
final class AppWindowSpaceCoordinator: AppWindowSpaceCoordinating {
  private let notificationCenter: NotificationCenter
  private let windowsProvider: @MainActor () -> [NSWindow]
  nonisolated(unsafe) private var mainWindowObserver: NSObjectProtocol?

  init(
    notificationCenter: NotificationCenter = .default,
    windowsProvider: @escaping @MainActor () -> [NSWindow] = { NSApp.windows }
  ) {
    self.notificationCenter = notificationCenter
    self.windowsProvider = windowsProvider
    mainWindowObserver = notificationCenter.addObserver(
      forName: NSWindow.didBecomeMainNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated { [weak self] in
        self?.applyPolicy(to: window)
      }
    }
  }

  deinit {
    if let mainWindowObserver {
      notificationCenter.removeObserver(mainWindowObserver)
    }
  }

  func prepareVisibleWindowsForActivation() {
    windowsProvider().filter(\.isVisible).forEach(applyPolicy)
  }

  private func applyPolicy(to window: NSWindow) {
    guard !(window is NSPanel),
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
