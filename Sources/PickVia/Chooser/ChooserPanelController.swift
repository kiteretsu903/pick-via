import AppKit
import PickViaCore
import SwiftUI

@MainActor
public protocol ClipboardWriting: AnyObject {
  func write(_ string: String)
}

@MainActor
public final class SystemClipboardWriter: ClipboardWriting {
  public init() {}

  public func write(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
  }
}

@MainActor
public final class ChooserPanelController: NSObject, ChooserPresenting, NSWindowDelegate {
  private let clipboard: any ClipboardWriting
  private let openBrowserSettings: @MainActor () -> Void
  private let showsURL: Bool

  private var panel: NSPanel?
  private var hostingView: NSHostingView<ChooserView>?
  // NSEvent monitor tokens are opaque and non-Sendable. The controller owns the
  // token exclusively; this escape hatch lets nonisolated deinit remove it too.
  nonisolated(unsafe) private var keyMonitor: Any?
  private var presentation: ChooserPresentation?
  private var onSelection: ((BrowserTarget.ID) -> Void)?
  private var onCancel: (() -> Void)?
  private var isDismissing = false

  public init(
    clipboard: any ClipboardWriting = SystemClipboardWriter(),
    showsURL: Bool = true,
    openBrowserSettings: @escaping @MainActor () -> Void = {}
  ) {
    self.clipboard = clipboard
    self.showsURL = showsURL
    self.openBrowserSettings = openBrowserSettings
    super.init()
  }

  deinit {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
    }
  }

  public func present(
    request: RoutingRequest,
    applications: [BrowserApplication],
    targets: [BrowserTarget],
    error: LaunchFailure?,
    onSelection: @escaping (BrowserTarget.ID) -> Void,
    onCancel: @escaping () -> Void
  ) {
    let preservedTargetID: BrowserTarget.ID?
    if presentation?.request.id == request.id,
      let index = presentation?.selectedIndex,
      let rows = presentation?.rows,
      rows.indices.contains(index)
    {
      preservedTargetID = rows[index].targetID
    } else {
      preservedTargetID = nil
    }

    presentation = ChooserPresentation.make(
      request: request,
      applications: applications,
      targets: targets,
      error: error,
      preservingSelection: preservedTargetID
    )
    self.onSelection = onSelection
    self.onCancel = onCancel
    isDismissing = false

    render()
    installKeyMonitor()

    guard let panel else { return }
    position(panel)
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  public func dismiss() {
    guard !isDismissing else { return }
    isDismissing = true
    removeKeyMonitor()
    panel?.orderOut(nil)
    onSelection = nil
    onCancel = nil
    presentation = nil
    isDismissing = false
  }

  public func windowDidResignKey(_ notification: Notification) {
    guard notification.object as? NSPanel === panel, !isDismissing else { return }
    cancelAndDismiss()
  }

  func copyURL(_ url: URL) {
    clipboard.write(url.absoluteString)
  }

  func showBrowserSettings() {
    openBrowserSettings()
  }

  private func render() {
    guard let presentation else { return }
    let view = ChooserView(
      presentation: presentation,
      showsURL: showsURL,
      onSelection: { [weak self] targetID in self?.select(targetID) },
      onCopyURL: { [weak self] in self?.copyCurrentURL() },
      onOpenBrowserSettings: { [weak self] in self?.showBrowserSettings() },
      onCancel: { [weak self] in self?.cancelAndDismiss() }
    )

    if let hostingView {
      hostingView.rootView = view
    } else {
      let hostingView = NSHostingView(rootView: view)
      self.hostingView = hostingView
      let panel = ChooserPanel(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
      )
      panel.delegate = self
      panel.contentView = hostingView
      panel.isReleasedWhenClosed = false
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.collectionBehavior = [.transient, .moveToActiveSpace]
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = true
      self.panel = panel
    }

    guard let hostingView, let panel else { return }
    hostingView.layoutSubtreeIfNeeded()
    let fittingSize = hostingView.fittingSize
    panel.setContentSize(NSSize(width: 480, height: max(180, fittingSize.height)))
  }

  private func position(_ panel: NSPanel) {
    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    guard let visibleFrame = screen?.visibleFrame else {
      panel.center()
      return
    }
    let frame = panel.frame
    panel.setFrameOrigin(
      NSPoint(
        x: visibleFrame.midX - frame.width / 2,
        y: visibleFrame.midY - frame.height / 2
      ))
  }

  private func installKeyMonitor() {
    removeKeyMonitor()
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.handle(event) ? nil : event
    }
  }

  private func removeKeyMonitor() {
    guard let keyMonitor else { return }
    NSEvent.removeMonitor(keyMonitor)
    self.keyMonitor = nil
  }

  private func handle(_ event: NSEvent) -> Bool {
    let key: ChooserKey?
    switch event.keyCode {
    case 126: key = .up
    case 125: key = .down
    case 36, 76: key = .returnKey
    case 53: key = .escape
    default:
      if let character = event.charactersIgnoringModifiers?.first,
        let number = character.wholeNumberValue,
        (1...9).contains(number)
      {
        key = .number(number)
      } else {
        key = nil
      }
    }

    guard let key else { return false }
    switch key {
    case .up:
      presentation?.moveSelection(.up)
      render()
    case .down:
      presentation?.moveSelection(.down)
      render()
    default:
      guard let action = presentation?.handle(key) else { return false }
      perform(action)
    }
    return true
  }

  private func perform(_ action: ChooserAction) {
    switch action {
    case .select(let targetID): select(targetID)
    case .cancel: cancelAndDismiss()
    case .none: break
    }
  }

  private func select(_ targetID: BrowserTarget.ID) {
    onSelection?(targetID)
  }

  private func copyCurrentURL() {
    guard let url = presentation?.request.url else { return }
    copyURL(url)
  }

  private func cancelAndDismiss() {
    guard !isDismissing else { return }
    let callback = onCancel
    dismiss()
    callback?()
  }
}

private final class ChooserPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}
