public enum BrowserLaunchMechanism: Equatable, Sendable {
  case process
  case workspace
  case safariAccessibility
  case duckDuckGo
}

public struct BrowserLaunchObservation: Equatable, Sendable {
  public let processIdentifier: Int32
  public let mechanism: BrowserLaunchMechanism

  public init?(
    processIdentifier: Int32,
    mechanism: BrowserLaunchMechanism
  ) {
    guard processIdentifier > 0 else { return nil }
    self.processIdentifier = processIdentifier
    self.mechanism = mechanism
  }
}
