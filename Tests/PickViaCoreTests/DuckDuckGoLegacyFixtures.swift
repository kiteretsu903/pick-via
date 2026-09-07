import Foundation

@testable import PickViaCore

// Reproduce the on-disk format shipped before Session.json. Production writes only journals.
extension DuckDuckGoManagedStateStore {
  func writeLegacy(_ marker: DuckDuckGoManagedProcessMarker, for session: DuckDuckGoManagedSession)
    throws
  {
    try JSONEncoder().encode(marker).write(to: session.markerURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: session.markerURL.path)
  }
  func writeLegacy(
    _ marker: DuckDuckGoLaunchQuarantineMarker, for session: DuckDuckGoManagedSession
  ) throws {
    try JSONEncoder().encode(marker).write(to: session.quarantineURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: session.quarantineURL.path)
  }
}
