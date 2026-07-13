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
  func present(model: AppModel, onClose: @escaping @MainActor () -> Void)
  func dismissAndRestoreWindows()
}

@MainActor
public final class ProfileAccessPanelController: ProfileAccessPresenting {
  private let driver: any ProfileAccessPanelDriving
  private weak var pendingModel: AppModel?
  private weak var presentedModel: AppModel?
  private var isPresented = false

  init(driver: any ProfileAccessPanelDriving) {
    self.driver = driver
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
    pendingModel = nil
    isPresented = true
    presentedModel = model
    driver.hideCompetingPickViaWindows()
    driver.present(model: model) { [weak self, weak model] in
      model?.closeProfileAccess()
      self?.dismiss()
    }
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

@MainActor
final class AppKitProfileAccessPanelDriver: NSObject, ProfileAccessPanelDriving, NSWindowDelegate {
  typealias WizardViewFactory = @MainActor (AppModel) -> AnyView

  var environmentDidChangeHandler: (@MainActor () -> Void)?

  private let notificationCenter: NotificationCenter
  private let isChooserActive: @MainActor () -> Bool
  private var wizardViewFactory: WizardViewFactory?
  private var onClose: (@MainActor () -> Void)?
  private var hiddenWindows: [NSWindow] = []
  nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []

  init(
    notificationCenter: NotificationCenter = .default,
    isChooserActive: @escaping @MainActor () -> Bool = { false }
  ) {
    self.notificationCenter = notificationCenter
    self.isChooserActive = isChooserActive
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

  func present(model: AppModel, onClose: @escaping @MainActor () -> Void) {
    guard let wizardViewFactory else { return }
    self.onClose = onClose
    panel.contentViewController = NSHostingController(rootView: wizardViewFactory(model))
    panel.center()
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
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
