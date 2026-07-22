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
  private let showsURLProvider: @MainActor () -> Bool
  private let densityProvider: @MainActor () -> ChooserDensity
  private let onPresentationChange: @MainActor (Bool) -> Void
  private let pointerLocationProvider: @MainActor () -> NSPoint

  private(set) var showsURLForCurrentPresentation = true
  private(set) var densityForCurrentPresentation: ChooserDensity = .compact

  private var panel: NSPanel?
  private var hostingView: NSHostingView<ChooserView>?
  private var pointerAnchor: NSPoint?
  private var maximumContentHeightForCurrentPresentation: CGFloat?
  private var visibleFrameForCurrentPresentation: CGRect?
  // NSEvent monitor tokens are opaque and non-Sendable. The controller owns the
  // token exclusively; this escape hatch lets nonisolated deinit remove it too.
  nonisolated(unsafe) private var keyMonitor: Any?
  private var presentation: ChooserPresentation?
  private var onSelection: ((BrowserTarget.ID) -> Void)?
  private var onCancel: (() -> Void)?
  private var isDismissing = false
  private var suppressesResignCancellation = false
  private var hasReportedPresentation = false
  private var isPresentationEndReportScheduled = false

  var hasActivePresentation: Bool { presentation != nil }
  var isKeyboardMonitorInstalled: Bool { keyMonitor != nil }
  var pointerAnchorForCurrentPresentation: NSPoint? { pointerAnchor }
  var panelContentSizeForTesting: NSSize {
    panel.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero
  }
  var panelFrameForTesting: NSRect { panel?.frame ?? .zero }

  public init(
    clipboard: any ClipboardWriting = SystemClipboardWriter(),
    showsURL: Bool = true,
    densityProvider: @escaping @MainActor () -> ChooserDensity = { .compact },
    openBrowserSettings: @escaping @MainActor () -> Void = {},
    onPresentationChange: @escaping @MainActor (Bool) -> Void = { _ in },
    pointerLocationProvider: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation }
  ) {
    self.clipboard = clipboard
    self.showsURLProvider = { showsURL }
    self.densityProvider = densityProvider
    self.openBrowserSettings = openBrowserSettings
    self.onPresentationChange = onPresentationChange
    self.pointerLocationProvider = pointerLocationProvider
    super.init()
  }

  public init(
    showsURLProvider: @escaping @MainActor () -> Bool,
    densityProvider: @escaping @MainActor () -> ChooserDensity = { .compact },
    clipboard: any ClipboardWriting = SystemClipboardWriter(),
    openBrowserSettings: @escaping @MainActor () -> Void = {},
    onPresentationChange: @escaping @MainActor (Bool) -> Void = { _ in },
    pointerLocationProvider: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation }
  ) {
    self.clipboard = clipboard
    self.showsURLProvider = showsURLProvider
    self.densityProvider = densityProvider
    self.openBrowserSettings = openBrowserSettings
    self.onPresentationChange = onPresentationChange
    self.pointerLocationProvider = pointerLocationProvider
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
    let isNewRequest = presentation?.request.id != request.id
    if isNewRequest || pointerAnchor == nil {
      pointerAnchor = pointerLocationProvider()
    }
    if isNewRequest {
      densityForCurrentPresentation = densityProvider()
    }
    showsURLForCurrentPresentation = showsURLProvider()
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
    suppressesResignCancellation = false

    let screens = NSScreen.screens
    let placement = ChooserPanelLayout.placement(
      pointer: pointerAnchor,
      screenFrames: screens.map(\.frame)
    )
    let containingScreen: NSScreen? =
      switch placement {
      case .pointerAnchored(let screenIndex) where screens.indices.contains(screenIndex):
        screens[screenIndex]
      case .pointerAnchored, .centered:
        nil
      }
    let mainVisibleFrame = NSScreen.main?.visibleFrame
    let retainedOrigin = isNewRequest ? nil : panel?.frame.origin
    let visibleFrame =
      isNewRequest
      ? containingScreen?.visibleFrame ?? mainVisibleFrame
      : visibleFrameForCurrentPresentation
    if isNewRequest {
      visibleFrameForCurrentPresentation = visibleFrame
    }
    let maximumHeight: CGFloat?
    if let retainedOrigin, let visibleFrame {
      let remainingHeight = max(
        1,
        visibleFrame.maxY - ChooserPanelLayout.screenMargin - retainedOrigin.y
      )
      maximumHeight =
        maximumContentHeightForCurrentPresentation.map {
          min($0, remainingHeight)
        } ?? remainingHeight
    } else {
      maximumHeight = visibleFrame.map { ChooserPanelLayout.maximumPanelHeight(in: $0) }
    }
    maximumContentHeightForCurrentPresentation = maximumHeight
    render(maximumContentHeight: maximumHeight)
    if let retainedOrigin {
      panel?.setFrameOrigin(retainedOrigin)
    }
    installKeyMonitor()

    guard let panel else { return }
    if isNewRequest {
      if let pointerAnchor, let visibleFrame = containingScreen?.visibleFrame {
        panel.setFrameOrigin(
          ChooserPanelLayout.origin(
            pointer: pointerAnchor,
            panelSize: panel.frame.size,
            visibleFrame: visibleFrame
          )
        )
      } else if let mainVisibleFrame {
        panel.setFrameOrigin(
          ChooserPanelLayout.centeredOrigin(
            panelSize: panel.frame.size,
            visibleFrame: mainVisibleFrame
          )
        )
      }
    }
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
    if !hasReportedPresentation {
      hasReportedPresentation = true
      onPresentationChange(true)
    }
  }

  public func dismiss() {
    guard !isDismissing else { return }
    isDismissing = true
    removeKeyMonitor()
    panel?.orderOut(nil)
    onSelection = nil
    onCancel = nil
    presentation = nil
    pointerAnchor = nil
    maximumContentHeightForCurrentPresentation = nil
    visibleFrameForCurrentPresentation = nil
    suppressesResignCancellation = false
    isDismissing = false
    schedulePresentationEndReport()
  }

  public func windowDidResignKey(_ notification: Notification) {
    guard notification.object as? NSPanel === panel, !isDismissing else { return }
    handleResignKey()
  }

  public func windowWillClose(_ notification: Notification) {
    cancelAndDismiss()
  }

  func copyURL(_ url: URL) {
    clipboard.write(url.absoluteString)
  }

  func showBrowserSettings() {
    suppressesResignCancellation = true
    removeKeyMonitor()
    panel?.orderOut(nil)
    openBrowserSettings()
  }

  func resignKeyForTesting() {
    handleResignKey()
  }

  private func render(maximumContentHeight: CGFloat?) {
    guard let presentation else { return }
    let view = ChooserView(
      presentation: presentation,
      showsURL: showsURLForCurrentPresentation,
      density: densityForCurrentPresentation,
      maximumContentHeight: maximumContentHeight,
      onSelection: { [weak self] targetID in self?.select(targetID) },
      onCopyURL: { [weak self] in self?.copyCurrentURL() },
      onOpenBrowserSettings: { [weak self] in self?.showBrowserSettings() },
      onCancel: { [weak self] in self?.cancelAndDismiss() }
    )

    if let hostingView {
      hostingView.rootView = view
    } else {
      let contentWidth = densityForCurrentPresentation.metrics.contentWidth
      let hostingView = NSHostingView(rootView: view)
      self.hostingView = hostingView
      let panel = ChooserPanel(
        contentRect: NSRect(
          x: 0,
          y: 0,
          width: contentWidth,
          height: 300
        ),
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
    let contentWidth = densityForCurrentPresentation.metrics.contentWidth
    let fittingSize = hostingView.fittingSize
    let fittedHeight =
      maximumContentHeight.map { min($0, fittingSize.height) } ?? fittingSize.height
    panel.setContentSize(
      NSSize(
        width: contentWidth,
        height: max(1, fittedHeight)
      )
    )
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
      key = Self.shortcutKey(
        character: event.charactersIgnoringModifiers?.first,
        modifiers: event.modifierFlags
      )
    }

    guard let key else { return false }
    switch key {
    case .up:
      presentation?.moveSelection(.up)
      render(maximumContentHeight: maximumContentHeightForCurrentPresentation)
    case .down:
      presentation?.moveSelection(.down)
      render(maximumContentHeight: maximumContentHeightForCurrentPresentation)
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

  private func handleResignKey() {
    guard !suppressesResignCancellation else { return }
    cancelAndDismiss()
  }

  private func schedulePresentationEndReport() {
    guard hasReportedPresentation, !isPresentationEndReportScheduled else { return }
    isPresentationEndReportScheduled = true
    Task { @MainActor [weak self] in
      self?.reportPresentationEndedIfInactive()
    }
  }

  private func reportPresentationEndedIfInactive() {
    isPresentationEndReportScheduled = false
    guard hasReportedPresentation, presentation == nil else { return }
    hasReportedPresentation = false
    onPresentationChange(false)
  }

  static func shortcutKey(
    character: Character?,
    modifiers: NSEvent.ModifierFlags
  ) -> ChooserKey? {
    let disallowed: NSEvent.ModifierFlags = [.command, .option, .control]
    guard modifiers.intersection(disallowed).isEmpty,
      let shortcut = ChooserShortcut.parse(character)
    else { return nil }
    return .shortcut(shortcut)
  }
}

private final class ChooserPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}
