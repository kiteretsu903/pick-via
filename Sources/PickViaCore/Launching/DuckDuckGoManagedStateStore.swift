import Foundation

public struct DuckDuckGoManagedSession: Equatable, Sendable {
  public let identifier: UUID
  public let sessionDirectory: URL
  public let homeDirectory: URL
  public let markerURL: URL
  public let quarantineURL: URL

  public init(
    identifier: UUID,
    sessionDirectory: URL,
    homeDirectory: URL,
    markerURL: URL,
    quarantineURL: URL
  ) {
    self.identifier = identifier
    self.sessionDirectory = sessionDirectory
    self.homeDirectory = homeDirectory
    self.markerURL = markerURL
    self.quarantineURL = quarantineURL
  }
}

public struct DuckDuckGoLaunchQuarantineMarker: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let identifier: UUID
  public let processIdentifier: Int32
  public let launchDate: Date?
  public let applicationPath: String
  public let executablePath: String

  public init(
    identifier: UUID,
    processIdentifier: Int32,
    launchDate: Date?,
    applicationPath: String,
    executablePath: String
  ) {
    schemaVersion = 1
    self.identifier = identifier
    self.processIdentifier = processIdentifier
    self.launchDate = launchDate
    self.applicationPath = applicationPath
    self.executablePath = executablePath
  }
}

public struct DuckDuckGoLaunchQuarantineRecord: Equatable, Sendable {
  public let session: DuckDuckGoManagedSession
  public let marker: DuckDuckGoLaunchQuarantineMarker

  public init(
    session: DuckDuckGoManagedSession,
    marker: DuckDuckGoLaunchQuarantineMarker
  ) {
    self.session = session
    self.marker = marker
  }
}

public struct DuckDuckGoManagedProcessMarker: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let identifier: UUID
  public let processIdentifier: Int32
  public let launchDate: Date
  public let applicationPath: String
  public let executablePath: String

  public init(
    identifier: UUID,
    processIdentifier: Int32,
    launchDate: Date,
    applicationPath: String,
    executablePath: String
  ) {
    schemaVersion = 1
    self.identifier = identifier
    self.processIdentifier = processIdentifier
    self.launchDate = launchDate
    self.applicationPath = applicationPath
    self.executablePath = executablePath
  }
}

public struct DuckDuckGoManagedSessionRecord: Equatable, Sendable {
  public let session: DuckDuckGoManagedSession
  public let marker: DuckDuckGoManagedProcessMarker

  public init(
    session: DuckDuckGoManagedSession,
    marker: DuckDuckGoManagedProcessMarker
  ) {
    self.session = session
    self.marker = marker
  }
}

public protocol DuckDuckGoManagedStateStoring: Sendable {
  func prepareHome(identifier: UUID) throws -> DuckDuckGoManagedSession
  func save(
    _ marker: DuckDuckGoManagedProcessMarker,
    for session: DuckDuckGoManagedSession
  ) throws
  func records() throws -> [DuckDuckGoManagedSessionRecord]
  func saveQuarantine(
    _ marker: DuckDuckGoLaunchQuarantineMarker,
    for session: DuckDuckGoManagedSession
  ) throws
  func quarantineRecords() throws -> [DuckDuckGoLaunchQuarantineRecord]
  func removeQuarantine(for session: DuckDuckGoManagedSession) throws
  func removeSession(identifier: UUID) throws
}

public enum DuckDuckGoManagedStateStoreError: Error, Equatable, Sendable {
  case sessionAlreadyExists
  case invalidSession
  case markerIdentifierMismatch
}

public struct DuckDuckGoManagedStateStore: DuckDuckGoManagedStateStoring, Sendable {
  public static var defaultRootDirectory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appending(path: "PickVia/DuckDuckGoFire", directoryHint: .isDirectory)
  }

  public let rootDirectory: URL

  public init(rootDirectory: URL = Self.defaultRootDirectory) {
    self.rootDirectory = rootDirectory.standardizedFileURL
  }

  public func prepareHome(identifier: UUID = UUID()) throws
    -> DuckDuckGoManagedSession
  {
    let fileManager = FileManager.default
    try createRootIfNeeded(fileManager: fileManager)
    let session = derivedSession(identifier: identifier)
    guard !entryExists(at: session.sessionDirectory, fileManager: fileManager) else {
      throw DuckDuckGoManagedStateStoreError.sessionAlreadyExists
    }

    var createdSessionRoot = false
    do {
      try fileManager.createDirectory(
        at: session.sessionDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      createdSessionRoot = true
      try securePermissions(of: session.sessionDirectory, fileManager: fileManager)
      let appStoreDirectory = try createSessionDirectories(
        session: session,
        fileManager: fileManager
      )
      let appStore = appStoreDirectory.appending(path: "AppKeyValueStore")
      let defaults = session.homeDirectory.appending(
        path: "Library/Preferences/com.duckduckgo.macos.browser.plist"
      )
      try writePropertyList(
        ["startup-window-type": "fire-window"],
        to: appStore,
        fileManager: fileManager
      )
      try writePropertyList(
        [
          "contextual.onboarding.state": "completed",
          "onboarding.finished": true,
          "preferences.startup.restore-previous-session": false,
        ],
        to: defaults,
        fileManager: fileManager
      )
      return session
    } catch {
      if createdSessionRoot {
        try? fileManager.removeItem(at: session.sessionDirectory)
      }
      throw error
    }
  }

  public func save(
    _ marker: DuckDuckGoManagedProcessMarker,
    for session: DuckDuckGoManagedSession
  ) throws {
    let fileManager = FileManager.default
    try validateRoot(fileManager: fileManager)
    guard session == derivedSession(identifier: session.identifier),
      isDirectoryAndNotSymbolicLink(session.sessionDirectory, fileManager: fileManager)
    else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    guard marker.identifier == session.identifier else {
      throw DuckDuckGoManagedStateStoreError.markerIdentifierMismatch
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(marker)
    try data.write(to: session.markerURL, options: [.atomic])
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: session.markerURL.path
    )
  }

  public func records() throws -> [DuckDuckGoManagedSessionRecord] {
    let fileManager = FileManager.default
    guard entryExists(at: rootDirectory, fileManager: fileManager) else {
      return []
    }
    guard isDirectoryAndNotSymbolicLink(rootDirectory, fileManager: fileManager) else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }

    let children = try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    var result: [DuckDuckGoManagedSessionRecord] = []
    for child in children where !child.lastPathComponent.hasPrefix(".") {
      guard
        let identifier = UUID(uuidString: child.lastPathComponent),
        child.lastPathComponent == identifier.uuidString,
        isDirectoryAndNotSymbolicLink(child, fileManager: fileManager)
      else { continue }

      let session = derivedSession(identifier: identifier)
      guard isRegularFileAndNotSymbolicLink(session.markerURL, fileManager: fileManager),
        let data = try? Data(contentsOf: session.markerURL),
        let marker = try? JSONDecoder().decode(
          DuckDuckGoManagedProcessMarker.self,
          from: data
        ),
        marker.schemaVersion == 1,
        marker.identifier == identifier
      else { continue }
      result.append(DuckDuckGoManagedSessionRecord(session: session, marker: marker))
    }
    return result.sorted {
      $0.session.identifier.uuidString < $1.session.identifier.uuidString
    }
  }

  public func saveQuarantine(
    _ marker: DuckDuckGoLaunchQuarantineMarker,
    for session: DuckDuckGoManagedSession
  ) throws {
    let fileManager = FileManager.default
    try validateSession(session, fileManager: fileManager)
    guard marker.identifier == session.identifier else {
      throw DuckDuckGoManagedStateStoreError.markerIdentifierMismatch
    }
    if entryExists(at: session.quarantineURL, fileManager: fileManager),
      !isRegularFileAndNotSymbolicLink(session.quarantineURL, fileManager: fileManager)
    {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(marker)
    try data.write(to: session.quarantineURL, options: [.atomic])
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: session.quarantineURL.path
    )
  }

  public func quarantineRecords() throws -> [DuckDuckGoLaunchQuarantineRecord] {
    let fileManager = FileManager.default
    guard entryExists(at: rootDirectory, fileManager: fileManager) else {
      return []
    }
    guard isDirectoryAndNotSymbolicLink(rootDirectory, fileManager: fileManager) else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }

    let children = try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    var result: [DuckDuckGoLaunchQuarantineRecord] = []
    for child in children where !child.lastPathComponent.hasPrefix(".") {
      guard
        let identifier = UUID(uuidString: child.lastPathComponent),
        child.lastPathComponent == identifier.uuidString,
        isDirectoryAndNotSymbolicLink(child, fileManager: fileManager)
      else { continue }

      let session = derivedSession(identifier: identifier)
      guard isRegularFileAndNotSymbolicLink(session.quarantineURL, fileManager: fileManager),
        let data = try? Data(contentsOf: session.quarantineURL),
        let marker = try? JSONDecoder().decode(
          DuckDuckGoLaunchQuarantineMarker.self,
          from: data
        ),
        marker.schemaVersion == 1,
        marker.identifier == identifier
      else { continue }
      result.append(DuckDuckGoLaunchQuarantineRecord(session: session, marker: marker))
    }
    return result.sorted {
      $0.session.identifier.uuidString < $1.session.identifier.uuidString
    }
  }

  public func removeQuarantine(for session: DuckDuckGoManagedSession) throws {
    let fileManager = FileManager.default
    try validateSession(session, fileManager: fileManager)
    guard entryExists(at: session.quarantineURL, fileManager: fileManager) else {
      return
    }
    guard isRegularFileAndNotSymbolicLink(session.quarantineURL, fileManager: fileManager) else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    try fileManager.removeItem(at: session.quarantineURL)
  }

  public func removeSession(identifier: UUID) throws {
    let fileManager = FileManager.default
    try validateRoot(fileManager: fileManager)
    let session = derivedSession(identifier: identifier)
    guard entryExists(at: session.sessionDirectory, fileManager: fileManager) else {
      return
    }
    guard isDirectoryAndNotSymbolicLink(session.sessionDirectory, fileManager: fileManager)
    else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    try fileManager.removeItem(at: session.sessionDirectory)
  }

  private func derivedSession(identifier: UUID) -> DuckDuckGoManagedSession {
    let sessionDirectory = rootDirectory.appending(path: identifier.uuidString)
    return DuckDuckGoManagedSession(
      identifier: identifier,
      sessionDirectory: sessionDirectory,
      homeDirectory: sessionDirectory.appending(path: "Home"),
      markerURL: sessionDirectory.appending(path: "Process.json"),
      quarantineURL: sessionDirectory.appending(path: "Quarantine.json")
    )
  }

  private func createRootIfNeeded(fileManager: FileManager) throws {
    if entryExists(at: rootDirectory, fileManager: fileManager) {
      guard isDirectoryAndNotSymbolicLink(rootDirectory, fileManager: fileManager) else {
        throw DuckDuckGoManagedStateStoreError.invalidSession
      }
    } else {
      try fileManager.createDirectory(
        at: rootDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    }
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: rootDirectory.path
    )
  }

  private func createSessionDirectories(
    session: DuckDuckGoManagedSession,
    fileManager: FileManager
  ) throws -> URL {
    var directory = session.homeDirectory
    try createSecureDirectory(directory, fileManager: fileManager)
    for component in [
      "Library",
      "Containers",
      "com.duckduckgo.macos.browser",
      "Data",
      "Library",
      "Application Support",
    ] {
      directory.append(path: component, directoryHint: .isDirectory)
      try createSecureDirectory(directory, fileManager: fileManager)
    }

    let preferences = session.homeDirectory.appending(
      path: "Library/Preferences",
      directoryHint: .isDirectory
    )
    try createSecureDirectory(preferences, fileManager: fileManager)
    return directory
  }

  private func createSecureDirectory(_ url: URL, fileManager: FileManager) throws {
    try fileManager.createDirectory(
      at: url,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try securePermissions(of: url, fileManager: fileManager)
  }

  private func securePermissions(of url: URL, fileManager: FileManager) throws {
    try fileManager.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: url.path
    )
  }

  private func writePropertyList(
    _ values: [String: Any],
    to url: URL,
    fileManager: FileManager
  ) throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: values,
      format: .xml,
      options: 0
    )
    try data.write(to: url, options: [.atomic])
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
  }

  private func entryExists(at url: URL, fileManager: FileManager) -> Bool {
    (try? fileManager.attributesOfItem(atPath: url.path)) != nil
  }

  private func validateRoot(fileManager: FileManager) throws {
    guard isDirectoryAndNotSymbolicLink(rootDirectory, fileManager: fileManager) else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
  }

  private func validateSession(
    _ session: DuckDuckGoManagedSession,
    fileManager: FileManager
  ) throws {
    try validateRoot(fileManager: fileManager)
    guard session == derivedSession(identifier: session.identifier),
      isDirectoryAndNotSymbolicLink(session.sessionDirectory, fileManager: fileManager)
    else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
  }

  private func isDirectoryAndNotSymbolicLink(
    _ url: URL,
    fileManager: FileManager
  ) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
      return false
    }
    return attributes[.type] as? FileAttributeType == .typeDirectory
  }

  private func isRegularFileAndNotSymbolicLink(
    _ url: URL,
    fileManager: FileManager
  ) -> Bool {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
      return false
    }
    return attributes[.type] as? FileAttributeType == .typeRegular
  }
}
