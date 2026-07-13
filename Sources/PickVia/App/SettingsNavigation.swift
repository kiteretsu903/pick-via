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
struct BrowserSettingsRecovery {
  let navigation: SettingsNavigation
  let openSettings: @MainActor () -> Void

  func open() {
    navigation.destination = .browsers
    openSettings()
  }
}
