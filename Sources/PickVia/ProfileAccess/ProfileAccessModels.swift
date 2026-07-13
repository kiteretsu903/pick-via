import PickViaCore

public enum BrowserProfileAccessRowState: Equatable, Sendable {
  case accessNeeded
  case granted(profileCount: Int, persistence: ProfileGrantPersistence)
  case invalidFolder(requiredMarker: String)
  case accessRevoked
  case metadataDamaged
}

public struct BrowserProfileAccessRow: Identifiable, Equatable, Sendable {
  public var id: String { bundleIdentifier }

  public let bundleIdentifier: String
  public let displayName: String
  public let family: BrowserFamily
  public let expectedRootSuffix: String
  public let requiredMarker: String
  public var state: BrowserProfileAccessRowState
  public var hasStoredGrant: Bool
}

public enum ProfileAccessPresentationState: Equatable, Sendable {
  case idle
  case automaticPending
  case manualPending
  case presented
  case suppressedForProcess
}
