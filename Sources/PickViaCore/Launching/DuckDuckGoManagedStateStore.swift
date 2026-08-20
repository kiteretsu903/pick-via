import Darwin
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
  public let processIdentifier: Int32?
  public let launchDate: Date?
  public let applicationPath: String
  public let executablePath: String

  public init(
    identifier: UUID,
    processIdentifier: Int32?,
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

public enum DuckDuckGoLaunchQuarantineEntry: Equatable, Sendable {
  case valid(DuckDuckGoLaunchQuarantineRecord)
  case invalid(session: DuckDuckGoManagedSession)

  public var session: DuckDuckGoManagedSession {
    switch self {
    case .valid(let record):
      record.session
    case .invalid(let session):
      session
    }
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
  func quarantineEntries() throws -> [DuckDuckGoLaunchQuarantineEntry]
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
  private let removalDidOpenRoot: (@Sendable () throws -> Void)?
  private let removalWillDeleteEntry: (@Sendable (String) throws -> Void)?

  public init(rootDirectory: URL = Self.defaultRootDirectory) {
    self.rootDirectory = rootDirectory.standardizedFileURL
    removalDidOpenRoot = nil
    removalWillDeleteEntry = nil
  }

  init(
    rootDirectory: URL,
    removalDidOpenRoot: @escaping @Sendable () throws -> Void
  ) {
    self.rootDirectory = rootDirectory.standardizedFileURL
    self.removalDidOpenRoot = removalDidOpenRoot
    removalWillDeleteEntry = nil
  }

  init(
    rootDirectory: URL,
    removalWillDeleteEntry: @escaping @Sendable (String) throws -> Void
  ) {
    self.rootDirectory = rootDirectory.standardizedFileURL
    removalDidOpenRoot = nil
    self.removalWillDeleteEntry = removalWillDeleteEntry
  }

  public func prepareHome(identifier: UUID = UUID()) throws
    -> DuckDuckGoManagedSession
  {
    let fileManager = FileManager.default
    try createRootIfNeeded(fileManager: fileManager)
    let session = derivedSession(identifier: identifier)
    guard try !entryExists(at: session.sessionDirectory, fileManager: fileManager) else {
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
    guard try entryExists(at: rootDirectory, fileManager: fileManager) else {
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
    if try entryExists(at: session.quarantineURL, fileManager: fileManager),
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
    try quarantineEntries().compactMap { entry in
      guard case .valid(let record) = entry else { return nil }
      return record
    }
  }

  public func quarantineEntries() throws -> [DuckDuckGoLaunchQuarantineEntry] {
    let fileManager = FileManager.default
    guard try entryExists(at: rootDirectory, fileManager: fileManager) else {
      return []
    }
    guard isDirectoryAndNotSymbolicLink(rootDirectory, fileManager: fileManager) else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }

    let children = try fileManager.contentsOfDirectory(
      at: rootDirectory,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    )
    var result: [DuckDuckGoLaunchQuarantineEntry] = []
    for child in children where !child.lastPathComponent.hasPrefix(".") {
      guard
        let identifier = UUID(uuidString: child.lastPathComponent),
        child.lastPathComponent == identifier.uuidString
      else { continue }

      let session = derivedSession(identifier: identifier)
      guard isDirectoryAndNotSymbolicLink(child, fileManager: fileManager) else {
        result.append(.invalid(session: session))
        continue
      }
      guard try entryExists(at: session.quarantineURL, fileManager: fileManager) else {
        continue
      }
      guard isRegularFileAndNotSymbolicLink(session.quarantineURL, fileManager: fileManager),
        let data = try? Data(contentsOf: session.quarantineURL),
        let marker = try? JSONDecoder().decode(
          DuckDuckGoLaunchQuarantineMarker.self,
          from: data
        ),
        marker.schemaVersion == 1,
        marker.identifier == identifier
      else {
        result.append(.invalid(session: session))
        continue
      }
      result.append(
        .valid(DuckDuckGoLaunchQuarantineRecord(session: session, marker: marker))
      )
    }
    return result.sorted {
      $0.session.identifier.uuidString < $1.session.identifier.uuidString
    }
  }

  public func removeQuarantine(for session: DuckDuckGoManagedSession) throws {
    guard session == derivedSession(identifier: session.identifier) else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    let rootFileDescriptor = try openRootDirectory()
    defer { Darwin.close(rootFileDescriptor) }
    let sessionName = session.identifier.uuidString
    guard try relativeNodeType(parent: rootFileDescriptor, name: sessionName) == .directory else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    let sessionFileDescriptor = try openDirectory(
      parent: rootFileDescriptor,
      name: sessionName
    )
    defer { Darwin.close(sessionFileDescriptor) }
    guard
      let type = try relativeNodeTypeIfPresent(
        parent: sessionFileDescriptor,
        name: "Quarantine.json"
      )
    else { return }
    guard type == .regular else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    try unlinkRelative(parent: sessionFileDescriptor, name: "Quarantine.json")
  }

  public func removeSession(identifier: UUID) throws {
    let rootFileDescriptor = try openRootDirectory()
    defer { Darwin.close(rootFileDescriptor) }
    try removalDidOpenRoot?()
    let sessionName = identifier.uuidString
    guard
      let type = try relativeNodeTypeIfPresent(
        parent: rootFileDescriptor,
        name: sessionName
      )
    else { return }
    guard type == .directory else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    var sessionFileDescriptor = try openDirectory(
      parent: rootFileDescriptor,
      name: sessionName
    )
    defer {
      if sessionFileDescriptor >= 0 { Darwin.close(sessionFileDescriptor) }
    }
    let expectedStatus = try fileStatus(descriptor: sessionFileDescriptor)
    let tombstoneName = ".deleting-\(identifier.uuidString)-\(UUID().uuidString)"
    let renameResult = sessionName.withCString { source in
      tombstoneName.withCString { destination in
        renameatx_np(
          rootFileDescriptor,
          source,
          rootFileDescriptor,
          destination,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard renameResult == 0 else { throw currentPOSIXError() }
    do {
      guard
        let renamedStatus = try relativeStatusIfPresent(
          parent: rootFileDescriptor,
          name: tombstoneName
        ), sameFileIdentity(expectedStatus, renamedStatus),
        (renamedStatus.st_mode & S_IFMT) == S_IFDIR
      else {
        throw DuckDuckGoManagedStateStoreError.invalidSession
      }
      try removeDirectoryContents(
        sessionFileDescriptor,
        preservingAuthorityFiles: true
      )
      guard
        let emptiedStatus = try relativeStatusIfPresent(
          parent: rootFileDescriptor,
          name: tombstoneName
        ), sameFileIdentity(expectedStatus, emptiedStatus),
        (emptiedStatus.st_mode & S_IFMT) == S_IFDIR
      else {
        throw DuckDuckGoManagedStateStoreError.invalidSession
      }
      Darwin.close(sessionFileDescriptor)
      sessionFileDescriptor = -1
      let result = tombstoneName.withCString {
        unlinkat(rootFileDescriptor, $0, AT_REMOVEDIR)
      }
      guard result == 0 else { throw currentPOSIXError() }
    } catch {
      try? restoreTombstone(
        parent: rootFileDescriptor,
        tombstoneName: tombstoneName,
        sessionName: sessionName,
        expectedStatus: expectedStatus
      )
      throw error
    }
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
    if try entryExists(at: rootDirectory, fileManager: fileManager) {
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

  private func entryExists(at url: URL, fileManager: FileManager) throws -> Bool {
    do {
      _ = try fileManager.attributesOfItem(atPath: url.path)
      return true
    } catch {
      let value = error as NSError
      if value.domain == NSCocoaErrorDomain,
        value.code == CocoaError.Code.fileNoSuchFile.rawValue
      {
        return false
      }
      if value.domain == NSPOSIXErrorDomain, value.code == Int(ENOENT) {
        return false
      }
      if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError,
        underlying.domain == NSPOSIXErrorDomain,
        underlying.code == Int(ENOENT)
      {
        return false
      }
      throw error
    }
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

  private enum RelativeNodeType {
    case directory
    case regular
    case other
  }

  private func openRootDirectory() throws -> Int32 {
    let descriptor = Darwin.open(
      rootDirectory.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    return descriptor
  }

  private func openDirectory(parent: Int32, name: String) throws -> Int32 {
    let descriptor = name.withCString {
      openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw currentPOSIXError() }
    return descriptor
  }

  private func relativeNodeType(
    parent: Int32,
    name: String
  ) throws -> RelativeNodeType {
    guard let value = try relativeNodeTypeIfPresent(parent: parent, name: name) else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    return value
  }

  private func relativeNodeTypeIfPresent(
    parent: Int32,
    name: String
  ) throws -> RelativeNodeType? {
    guard let status = try relativeStatusIfPresent(parent: parent, name: name) else {
      return nil
    }
    switch status.st_mode & S_IFMT {
    case S_IFDIR:
      return .directory
    case S_IFREG:
      return .regular
    default:
      return .other
    }
  }

  private func relativeStatusIfPresent(
    parent: Int32,
    name: String
  ) throws -> stat? {
    var status = stat()
    let result = name.withCString {
      fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    if result != 0 {
      if errno == ENOENT { return nil }
      throw currentPOSIXError()
    }
    return status
  }

  private func unlinkRelative(parent: Int32, name: String) throws {
    let result = name.withCString { unlinkat(parent, $0, 0) }
    guard result == 0 else { throw currentPOSIXError() }
  }

  private func removeDirectoryContents(
    _ directoryFileDescriptor: Int32,
    preservingAuthorityFiles: Bool = false
  ) throws {
    let enumerationFileDescriptor = dup(directoryFileDescriptor)
    guard enumerationFileDescriptor >= 0 else { throw currentPOSIXError() }
    guard let directory = fdopendir(enumerationFileDescriptor) else {
      Darwin.close(enumerationFileDescriptor)
      throw currentPOSIXError()
    }
    defer { closedir(directory) }

    while let entry = readdir(directory) {
      let childName = withUnsafePointer(to: entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(
          to: CChar.self,
          capacity: Int(MAXNAMLEN) + 1
        ) { String(cString: $0) }
      }
      if childName == "." || childName == ".." { continue }
      if preservingAuthorityFiles,
        childName == "Process.json" || childName == "Quarantine.json"
      {
        continue
      }
      try removalWillDeleteEntry?(childName)
      switch try relativeNodeType(parent: directoryFileDescriptor, name: childName) {
      case .directory:
        let expectedStatus = try requiredRelativeStatus(
          parent: directoryFileDescriptor,
          name: childName
        )
        let childFileDescriptor = try openDirectory(
          parent: directoryFileDescriptor,
          name: childName
        )
        let openedStatus: stat
        do {
          openedStatus = try fileStatus(descriptor: childFileDescriptor)
          guard sameFileIdentity(expectedStatus, openedStatus) else {
            throw DuckDuckGoManagedStateStoreError.invalidSession
          }
          try removeDirectoryContents(childFileDescriptor)
        } catch {
          Darwin.close(childFileDescriptor)
          throw error
        }
        Darwin.close(childFileDescriptor)
        guard
          let currentStatus = try relativeStatusIfPresent(
            parent: directoryFileDescriptor,
            name: childName
          ), sameFileIdentity(openedStatus, currentStatus),
          (currentStatus.st_mode & S_IFMT) == S_IFDIR
        else {
          throw DuckDuckGoManagedStateStoreError.invalidSession
        }
        let result = childName.withCString {
          unlinkat(directoryFileDescriptor, $0, AT_REMOVEDIR)
        }
        guard result == 0 else { throw currentPOSIXError() }
      case .regular, .other:
        try unlinkRelative(parent: directoryFileDescriptor, name: childName)
      }
    }

    if preservingAuthorityFiles {
      for childName in ["Quarantine.json", "Process.json"]
      where try relativeNodeTypeIfPresent(
        parent: directoryFileDescriptor,
        name: childName
      ) != nil {
        try removalWillDeleteEntry?(childName)
        try unlinkRelative(parent: directoryFileDescriptor, name: childName)
      }
    }
  }

  private func restoreTombstone(
    parent: Int32,
    tombstoneName: String,
    sessionName: String,
    expectedStatus: stat
  ) throws {
    guard
      let tombstoneStatus = try relativeStatusIfPresent(
        parent: parent,
        name: tombstoneName
      ), sameFileIdentity(expectedStatus, tombstoneStatus),
      (tombstoneStatus.st_mode & S_IFMT) == S_IFDIR,
      try relativeStatusIfPresent(parent: parent, name: sessionName) == nil
    else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    let result = tombstoneName.withCString { source in
      sessionName.withCString { destination in
        renameatx_np(
          parent,
          source,
          parent,
          destination,
          UInt32(RENAME_EXCL)
        )
      }
    }
    guard result == 0 else { throw currentPOSIXError() }
  }

  private func fileStatus(descriptor: Int32) throws -> stat {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { throw currentPOSIXError() }
    return status
  }

  private func requiredRelativeStatus(parent: Int32, name: String) throws -> stat {
    guard let status = try relativeStatusIfPresent(parent: parent, name: name) else {
      throw DuckDuckGoManagedStateStoreError.invalidSession
    }
    return status
  }

  private func sameFileIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private func currentPOSIXError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
}
