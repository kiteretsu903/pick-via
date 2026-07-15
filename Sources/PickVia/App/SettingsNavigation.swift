import Observation

@MainActor
@Observable
public final class SettingsNavigation {
  public var destination: SettingsDestination

  public init(destination: SettingsDestination = .general) {
    self.destination = destination
  }
}

@MainActor
struct SettingsNavigationAction {
  let model: AppModel
  let navigation: SettingsNavigation
  let openSettings: @MainActor () -> Void

  var isEnabled: Bool {
    model.canPresentOrdinaryAppSurface
  }

  @discardableResult
  func open(_ destination: SettingsDestination) -> Bool {
    guard isEnabled else { return false }
    navigation.destination = destination
    openSettings()
    return true
  }
}

@MainActor
struct BrowserSettingsRecovery {
  let navigation: SettingsNavigation
  let openSettings: @MainActor () -> Void

  func open() {
    navigation.destination = .browsers
    openSettings()
  }
}
