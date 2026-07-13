@MainActor
public protocol ProfileAccessPresenting: AnyObject {
  func request(model: AppModel)
  func requestIfPending(model: AppModel)
  func environmentDidChange()
  func dismiss()
}

@MainActor
protocol ProfileAccessPanelDriving: AnyObject {
  var canPresent: Bool { get }
  func hideCompetingPickViaWindows()
  func present(model: AppModel, onClose: @escaping @MainActor () -> Void)
  func dismissAndRestoreWindows()
}

@MainActor
public final class ProfileAccessPanelController: ProfileAccessPresenting {
  private let driver: any ProfileAccessPanelDriving
  private weak var pendingModel: AppModel?
  private var isPresented = false

  init(driver: any ProfileAccessPanelDriving) {
    self.driver = driver
  }

  public func request(model: AppModel) {
    pendingModel = model
    presentIfPossible()
  }

  public func requestIfPending(model: AppModel) {
    switch model.profileAccessPresentation {
    case .automaticPending, .manualPending:
      request(model: model)
    case .idle, .presented, .suppressedForProcess:
      break
    }
  }

  public func environmentDidChange() {
    presentIfPossible()
  }

  public func dismiss() {
    guard isPresented else { return }
    isPresented = false
    driver.dismissAndRestoreWindows()
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
    driver.hideCompetingPickViaWindows()
    model.profileAccessDidPresent()
    driver.present(model: model) { [weak self] in
      self?.dismiss()
    }
  }
}
