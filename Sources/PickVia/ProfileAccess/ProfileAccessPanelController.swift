import AppKit
import SwiftUI

public protocol ProfileAccessPresenting: AnyObject, Sendable {
  @MainActor func request(model: AppModel)
  @MainActor func requestIfPending(model: AppModel)
  @MainActor func environmentDidChange()
  @MainActor func dismiss()
}

@MainActor
protocol ProfileAccessPanelDriving: AnyObject {
  var environmentDidChangeHandler: (@MainActor () -> Void)? { get set }
  var canPresent: Bool { get }
  func hideCompetingPickViaWindows()
  func present(model: AppModel, onClose: @escaping @MainActor () -> Void) -> Bool
  func dismissAndRestoreWindows()
}

@MainActor
public final class ProfileAccessPanelController: ProfileAccessPresenting {
  private let driver: any ProfileAccessPanelDriving
  private let selectionCoordinator: ProfileAccessWizardSelectionCoordinator?
  private weak var pendingModel: AppModel?
  private weak var presentedModel: AppModel?
  private var isPresented = false

  init(
    driver: any ProfileAccessPanelDriving,
    selectionCoordinator: ProfileAccessWizardSelectionCoordinator? = nil
  ) {
    self.driver = driver
    self.selectionCoordinator = selectionCoordinator
    driver.environmentDidChangeHandler = { [weak self] in
      self?.environmentDidChange()
    }
  }

  isolated deinit {
    cleanupPresentation()
  }

  public func request(model: AppModel) {
    pendingModel = model
    presentIfPossible()
  }

  public func requestIfPending(model: AppModel) {
    switch model.profileAccessPresentation {
    case .automaticPending:
      guard model.onboardingStep >= 3 else { return }
      request(model: model)
    case .manualPending:
      request(model: model)
    case .idle, .presented, .suppressedForProcess:
      break
    }
  }

  public func environmentDidChange() {
    presentIfPossible()
  }

  public func dismiss() {
    cleanupPresentation()
  }

  private func cleanupPresentation() {
    guard isPresented else { return }
    isPresented = false
    selectionCoordinator?.endPresentation()
    driver.dismissAndRestoreWindows()
    let model = presentedModel
    presentedModel = nil
    model?.profileAccessDidDismiss()
  }

  private func presentIfPossible() {
    guard !isPresented, let model = pendingModel else { return }
    switch model.profileAccessPresentation {
    case .automaticPending, .manualPending:
      break
    case .idle, .presented, .suppressedForProcess:
      pendingModel = nil
      return
    }
    guard driver.canPresent else { return }
    selectionCoordinator?.beginPresentation()
    driver.hideCompetingPickViaWindows()
    let didPresent = driver.present(model: model) { [weak self, weak model] in
      model?.closeProfileAccess()
      self?.dismiss()
    }
    guard didPresent else {
      selectionCoordinator?.endPresentation()
      driver.dismissAndRestoreWindows()
      return
    }

    pendingModel = nil
    isPresented = true
    presentedModel = model
    model.profileAccessDidPresent()
  }
}

private final class InactiveProfileAccessPresenter: ProfileAccessPresenting, @unchecked Sendable {
  static let shared = InactiveProfileAccessPresenter()

  @MainActor func request(model: AppModel) {}
  @MainActor func requestIfPending(model: AppModel) {}
  @MainActor func environmentDidChange() {}
  @MainActor func dismiss() {}
}

private struct ProfileAccessPresenterEnvironmentKey: EnvironmentKey {
  static let defaultValue: any ProfileAccessPresenting = InactiveProfileAccessPresenter.shared
}

extension EnvironmentValues {
  @MainActor
  var profileAccessPresenter: any ProfileAccessPresenting {
    get { self[ProfileAccessPresenterEnvironmentKey.self] }
    set { self[ProfileAccessPresenterEnvironmentKey.self] = newValue }
  }
}

func profileAccessPanelOrigin(panelSize: NSSize, visibleFrame: NSRect) -> NSPoint {
  NSPoint(
    x: visibleFrame.midX - panelSize.width / 2,
    y: visibleFrame.midY - panelSize.height / 2
  )
}

@MainActor
final class AppKitProfileAccessPanelDriver: NSObject, ProfileAccessPanelDriving, NSWindowDelegate {
  typealias WizardViewFactory = @MainActor (AppModel) -> AnyView

  var environmentDidChangeHandler: (@MainActor () -> Void)?

  private let notificationCenter: NotificationCenter
  private let isChooserActive: @MainActor () -> Bool
  private let orderPanelFront: @MainActor (NSPanel) -> Void
  private let activateApplication: @MainActor () -> Void
  private let makePanelKey: @MainActor (NSPanel) -> Void
  private var wizardViewFactory: WizardViewFactory?
  private var onClose: (@MainActor () -> Void)?
  private var hiddenWindows: [NSWindow] = []
  nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []

  init(
    notificationCenter: NotificationCenter = .default,
    isChooserActive: @escaping @MainActor () -> Bool = { false },
    orderPanelFront: @escaping @MainActor (NSPanel) -> Void = {
      $0.orderFrontRegardless()
    },
    activateApplication: @escaping @MainActor () -> Void = {
      NSApp.activate(ignoringOtherApps: true)
    },
    makePanelKey: @escaping @MainActor (NSPanel) -> Void = { $0.makeKey() }
  ) {
    self.notificationCenter = notificationCenter
    self.isChooserActive = isChooserActive
    self.orderPanelFront = orderPanelFront
    self.activateApplication = activateApplication
    self.makePanelKey = makePanelKey
    super.init()
    lifecycleObservers = [
      NSWindow.didEndSheetNotification,
      NSWindow.willCloseNotification,
    ].map { name in
      notificationCenter.addObserver(
        forName: name,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.environmentDidChangeHandler?()
        }
      }
    }
  }

  deinit {
    for observer in lifecycleObservers {
      notificationCenter.removeObserver(observer)
    }
  }

  private lazy var panel: NSPanel = {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    panel.title = "Browser Profile Access"
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.delegate = self
    return panel
  }()

  var canPresent: Bool {
    !isChooserActive()
      && wizardViewFactory != nil
      && !panel.isVisible
      && NSApp.modalWindow == nil
      && !NSApp.windows.contains(where: { $0.attachedSheet != nil })
      && !NSApp.windows.contains(where: { window in
        window !== panel && window.isVisible && window is NSPanel
      })
  }

  func attachWizardViewFactory(_ factory: @escaping WizardViewFactory) {
    wizardViewFactory = factory
  }

  func hideCompetingPickViaWindows() {
    hiddenWindows = NSApp.windows.filter { window in
      window !== panel
        && window.isVisible
        && !window.isSheet
        && !(window is NSPanel)
        && window.level == .normal
    }
    for window in hiddenWindows {
      window.orderOut(nil)
    }
  }

  private func position(_ panel: NSPanel) {
    let pointer = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { screen in
        NSMouseInRect(pointer, screen.frame, false)
      } ?? NSScreen.main

    guard let visibleFrame = screen?.visibleFrame else {
      panel.center()
      return
    }

    panel.setFrameOrigin(
      profileAccessPanelOrigin(
        panelSize: panel.frame.size,
        visibleFrame: visibleFrame
      )
    )
  }

  func present(model: AppModel, onClose: @escaping @MainActor () -> Void) -> Bool {
    guard let wizardViewFactory else { return false }
    self.onClose = onClose
    panel.contentViewController = NSHostingController(rootView: wizardViewFactory(model))
    position(panel)
    orderPanelFront(panel)
    guard panel.isVisible else {
      self.onClose = nil
      return false
    }
    activateApplication()
    makePanelKey(panel)
    return true
  }

  func dismissAndRestoreWindows() {
    onClose = nil
    panel.orderOut(nil)
    let windowsToRestore = hiddenWindows
    hiddenWindows = []
    for window in windowsToRestore where !window.isVisible {
      window.orderFront(nil)
    }
    windowsToRestore.last?.makeKey()
  }

  func windowWillClose(_ notification: Notification) {
    guard notification.object as? NSWindow === panel else { return }
    let close = onClose
    onClose = nil
    close?()
  }
}
