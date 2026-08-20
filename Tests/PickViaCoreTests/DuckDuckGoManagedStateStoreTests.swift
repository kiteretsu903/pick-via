import Foundation
import Testing

@testable import PickViaCore

@Suite("DuckDuckGo managed state store")
struct DuckDuckGoManagedStateStoreTests {
  private let fixedIdentifier = UUID(
    uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
  )!

  @Test func prepareHomeWritesOnlyIsolatedFirePreferences() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)

    let session = try store.prepareHome(identifier: fixedIdentifier)

    let appStore = session.homeDirectory.appending(
      path:
        "Library/Containers/com.duckduckgo.macos.browser/Data/Library/Application Support/AppKeyValueStore"
    )
    let defaults = session.homeDirectory.appending(
      path: "Library/Preferences/com.duckduckgo.macos.browser.plist"
    )
    let appValues = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: appStore),
        format: nil
      ) as? [String: Any]
    )
    let defaultValues = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: defaults),
        format: nil
      ) as? [String: Any]
    )

    #expect(session.identifier == fixedIdentifier)
    #expect(session.sessionDirectory == root.appending(path: fixedIdentifier.uuidString))
    #expect(session.homeDirectory == session.sessionDirectory.appending(path: "Home"))
    #expect(session.markerURL == session.sessionDirectory.appending(path: "Process.json"))
    #expect(
      session.quarantineURL == session.sessionDirectory.appending(path: "Quarantine.json")
    )
    #expect(appValues.count == 1)
    #expect(appValues["startup-window-type"] as? String == "fire-window")
    #expect(defaultValues.count == 3)
    #expect(defaultValues["contextual.onboarding.state"] as? String == "completed")
    #expect(defaultValues["onboarding.finished"] as? Bool == true)
    #expect(
      defaultValues["preferences.startup.restore-previous-session"] as? Bool
        == false
    )
    #expect(
      !appStore.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path)
    )
  }

  @Test func prepareHomeSecuresEveryCreatedDirectoryAndFile() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)

    let session = try store.prepareHome(identifier: fixedIdentifier)
    let enumerator = try #require(
      FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey]
      )
    )
    let descendants = enumerator.compactMap { $0 as? URL }

    #expect(try permissions(of: root) == 0o700)
    for url in descendants {
      let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
      #expect(try permissions(of: url) == (isDirectory ? 0o700 : 0o600))
    }
    #expect(!FileManager.default.fileExists(atPath: session.markerURL.path))
  }

  @Test func prepareHomeRejectsExistingSessionWithoutChangingIt() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionDirectory = root.appending(path: fixedIdentifier.uuidString)
    try FileManager.default.createDirectory(
      at: sessionDirectory,
      withIntermediateDirectories: true
    )
    let sentinel = sessionDirectory.appending(path: "keep")
    try Data("keep".utf8).write(to: sentinel)
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)

    #expect(throws: DuckDuckGoManagedStateStoreError.sessionAlreadyExists) {
      try store.prepareHome(identifier: fixedIdentifier)
    }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
  }

  @Test func prepareHomeRejectsSymlinkSessionRoot() throws {
    let root = temporaryRoot()
    let target = temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: target)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let sessionDirectory = root.appending(path: fixedIdentifier.uuidString)
    try FileManager.default.createSymbolicLink(at: sessionDirectory, withDestinationURL: target)
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)

    #expect(throws: DuckDuckGoManagedStateStoreError.sessionAlreadyExists) {
      try store.prepareHome(identifier: fixedIdentifier)
    }
    #expect(FileManager.default.fileExists(atPath: target.path))
  }

  @Test func markerRoundTripsAsSortedJSONWithoutPersistingURL() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try store.prepareHome(identifier: fixedIdentifier)
    let marker = marker(identifier: session.identifier)

    try store.save(marker, for: session)

    #expect(
      try store.records()
        == [DuckDuckGoManagedSessionRecord(session: session, marker: marker)]
    )
    let text = try String(contentsOf: session.markerURL, encoding: .utf8)
    #expect(!text.contains("http://"))
    #expect(!text.contains("https://"))
    #expect(!text.contains("file://"))
    #expect(
      orderedRanges(
        of: [
          "applicationPath", "executablePath", "identifier", "launchDate",
          "processIdentifier", "schemaVersion",
        ],
        in: text
      )
    )
    #expect(try permissions(of: session.markerURL) == 0o600)
  }

  @Test func quarantineRoundTripsWithOptionalExactLaunchIdentity() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try store.prepareHome(identifier: fixedIdentifier)
    let quarantine = quarantineMarker(
      identifier: session.identifier,
      launchDate: nil
    )

    try store.saveQuarantine(quarantine, for: session)

    #expect(
      try store.quarantineRecords()
        == [DuckDuckGoLaunchQuarantineRecord(session: session, marker: quarantine)]
    )
    let text = try String(contentsOf: session.quarantineURL, encoding: .utf8)
    #expect(!text.contains("http://"))
    #expect(!text.contains("https://"))
    #expect(!text.contains("file://"))
    #expect(!text.contains("launchDate"))
    #expect(
      orderedRanges(
        of: [
          "applicationPath", "executablePath", "identifier", "processIdentifier",
          "schemaVersion",
        ],
        in: text
      )
    )
    #expect(try permissions(of: session.quarantineURL) == 0o600)
  }

  @Test func pendingQuarantineWithoutPIDIsAValidDurableEntry() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try store.prepareHome(identifier: fixedIdentifier)
    let pending = DuckDuckGoLaunchQuarantineMarker(
      identifier: session.identifier,
      processIdentifier: nil,
      launchDate: nil,
      applicationPath: "/Applications/DuckDuckGo.app",
      executablePath: "/Applications/DuckDuckGo.app/Contents/MacOS/DuckDuckGo"
    )

    try store.saveQuarantine(pending, for: session)

    #expect(
      try store.quarantineEntries()
        == [.valid(DuckDuckGoLaunchQuarantineRecord(session: session, marker: pending))]
    )
    let text = try String(contentsOf: session.quarantineURL, encoding: .utf8)
    #expect(!text.contains("processIdentifier"))
    #expect(!text.contains("launchDate"))
  }

  @Test func quarantineRecordsIgnoreCorruptSchemaAndSymlinkWithoutDeleting() throws {
    let root = temporaryRoot()
    let externalMarker = root.deletingLastPathComponent()
      .appending(path: "PickViaExternalQuarantine-\(UUID()).json")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: externalMarker)
    }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let validSession = try store.prepareHome(identifier: fixedIdentifier)
    let validMarker = quarantineMarker(identifier: fixedIdentifier, launchDate: Date())
    try store.saveQuarantine(validMarker, for: validSession)

    let corruptID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let corruptSession = try store.prepareHome(identifier: corruptID)
    try Data("not json".utf8).write(to: corruptSession.quarantineURL)
    let schemaID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    let schemaSession = try store.prepareHome(identifier: schemaID)
    try quarantineData(identifier: schemaID, schemaVersion: 2)
      .write(to: schemaSession.quarantineURL)
    let symlinkID = UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
    let symlinkSession = try store.prepareHome(identifier: symlinkID)
    try quarantineData(identifier: symlinkID, schemaVersion: 1).write(to: externalMarker)
    try FileManager.default.createSymbolicLink(
      at: symlinkSession.quarantineURL,
      withDestinationURL: externalMarker
    )

    #expect(
      try store.quarantineRecords()
        == [DuckDuckGoLaunchQuarantineRecord(session: validSession, marker: validMarker)]
    )
    #expect(FileManager.default.fileExists(atPath: corruptSession.quarantineURL.path))
    #expect(FileManager.default.fileExists(atPath: schemaSession.quarantineURL.path))
    #expect(try symbolicLinkExists(at: symlinkSession.quarantineURL))
    #expect(FileManager.default.fileExists(atPath: externalMarker.path))
    #expect(
      try store.quarantineEntries() == [
        .invalid(session: corruptSession),
        .invalid(session: schemaSession),
        .invalid(session: symlinkSession),
        .valid(DuckDuckGoLaunchQuarantineRecord(session: validSession, marker: validMarker)),
      ]
    )
  }

  @Test func quarantineRemovalLeavesManagedMarkerAndSessionIntact() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try store.prepareHome(identifier: fixedIdentifier)
    try store.save(marker(identifier: fixedIdentifier), for: session)
    try store.saveQuarantine(
      quarantineMarker(identifier: fixedIdentifier, launchDate: Date()),
      for: session
    )

    try store.removeQuarantine(for: session)

    #expect(!FileManager.default.fileExists(atPath: session.quarantineURL.path))
    #expect(FileManager.default.fileExists(atPath: session.markerURL.path))
    #expect(FileManager.default.fileExists(atPath: session.homeDirectory.path))
  }

  @Test func quarantineRemovalRejectsSessionSwappedBetweenStatAndOpen() throws {
    let root = temporaryRoot()
    let movedOriginal = temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: movedOriginal)
    }
    let initialStore = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try initialStore.prepareHome(identifier: fixedIdentifier)
    try initialStore.saveQuarantine(
      quarantineMarker(identifier: fixedIdentifier, launchDate: Date()),
      for: session
    )
    let originalQuarantine = try Data(contentsOf: session.quarantineURL)
    let replacementQuarantine = Data("replacement authority".utf8)
    let swappingStore = DuckDuckGoManagedStateStore(
      rootDirectory: root,
      removalWillOpenSession: {
        try FileManager.default.moveItem(
          at: session.sessionDirectory,
          to: movedOriginal
        )
        try FileManager.default.createDirectory(
          at: session.sessionDirectory,
          withIntermediateDirectories: false
        )
        try replacementQuarantine.write(to: session.quarantineURL)
      }
    )

    #expect(throws: DuckDuckGoManagedStateStoreError.invalidSession) {
      try swappingStore.removeQuarantine(for: session)
    }

    #expect(
      try Data(contentsOf: movedOriginal.appending(path: "Quarantine.json"))
        == originalQuarantine
    )
    #expect(try Data(contentsOf: session.quarantineURL) == replacementQuarantine)
  }

  @Test func quarantineMutationRejectsForeignSessionAndMarkerSymlink() throws {
    let root = temporaryRoot()
    let foreignRoot = temporaryRoot()
    let externalMarker = root.deletingLastPathComponent()
      .appending(path: "PickViaExternalQuarantine-\(UUID()).json")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: foreignRoot)
      try? FileManager.default.removeItem(at: externalMarker)
    }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let foreignStore = DuckDuckGoManagedStateStore(rootDirectory: foreignRoot)
    let foreignSession = try foreignStore.prepareHome(identifier: fixedIdentifier)

    #expect(throws: DuckDuckGoManagedStateStoreError.invalidSession) {
      try store.saveQuarantine(
        quarantineMarker(identifier: fixedIdentifier, launchDate: nil),
        for: foreignSession
      )
    }

    let session = try store.prepareHome(identifier: fixedIdentifier)
    try Data("keep".utf8).write(to: externalMarker)
    try FileManager.default.createSymbolicLink(
      at: session.quarantineURL,
      withDestinationURL: externalMarker
    )
    #expect(throws: DuckDuckGoManagedStateStoreError.invalidSession) {
      try store.saveQuarantine(
        quarantineMarker(identifier: fixedIdentifier, launchDate: nil),
        for: session
      )
    }
    #expect(throws: DuckDuckGoManagedStateStoreError.invalidSession) {
      try store.removeQuarantine(for: session)
    }
    #expect(try symbolicLinkExists(at: session.quarantineURL))
    #expect(try Data(contentsOf: externalMarker) == Data("keep".utf8))
  }

  @Test func uuidSessionSymlinkIsOpaqueAndItsTargetIsNeverRemoved() throws {
    let root = temporaryRoot()
    let target = temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: target)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let sentinel = target.appending(path: "keep")
    try Data("keep".utf8).write(to: sentinel)
    let sessionDirectory = root.appending(path: fixedIdentifier.uuidString)
    try FileManager.default.createSymbolicLink(
      at: sessionDirectory,
      withDestinationURL: target
    )
    let session = DuckDuckGoManagedSession(
      identifier: fixedIdentifier,
      sessionDirectory: sessionDirectory,
      homeDirectory: sessionDirectory.appending(path: "Home"),
      markerURL: sessionDirectory.appending(path: "Process.json"),
      quarantineURL: sessionDirectory.appending(path: "Quarantine.json")
    )
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)

    #expect(try store.quarantineEntries() == [.invalid(session: session)])
    #expect(throws: DuckDuckGoManagedStateStoreError.invalidSession) {
      try store.removeSession(identifier: fixedIdentifier)
    }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    #expect(try symbolicLinkExists(at: sessionDirectory))
  }

  @Test func inaccessibleQuarantineMetadataFailsClosed() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try store.prepareHome(identifier: fixedIdentifier)
    try store.saveQuarantine(
      quarantineMarker(identifier: fixedIdentifier, launchDate: Date()),
      for: session
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000],
      ofItemAtPath: session.sessionDirectory.path
    )
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: session.sessionDirectory.path
      )
    }

    #expect(throws: (any Error).self) {
      try store.quarantineEntries()
    }
  }

  @Test func saveRejectsSessionNotDerivedFromStoreRoot() throws {
    let root = temporaryRoot()
    let foreignRoot = temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: foreignRoot)
    }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let foreignStore = DuckDuckGoManagedStateStore(rootDirectory: foreignRoot)
    let foreignSession = try foreignStore.prepareHome(identifier: fixedIdentifier)

    #expect(throws: DuckDuckGoManagedStateStoreError.invalidSession) {
      try store.save(marker(identifier: fixedIdentifier), for: foreignSession)
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  @Test func saveRejectsMarkerForAnotherSession() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try store.prepareHome(identifier: fixedIdentifier)

    #expect(throws: DuckDuckGoManagedStateStoreError.markerIdentifierMismatch) {
      try store.save(marker(identifier: UUID()), for: session)
    }
    #expect(!FileManager.default.fileExists(atPath: session.markerURL.path))
  }

  @Test func saveRejectsStoreRootReplacedBySymlink() throws {
    let root = temporaryRoot()
    let originalRoot = temporaryRoot()
    let redirectTarget = temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: originalRoot)
      try? FileManager.default.removeItem(at: redirectTarget)
    }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try store.prepareHome(identifier: fixedIdentifier)
    try replaceStoreRoot(
      root,
      originalRoot: originalRoot,
      redirectTarget: redirectTarget,
      identifier: fixedIdentifier
    )
    let sentinel = redirectTarget.appending(path: fixedIdentifier.uuidString)
      .appending(path: "keep")

    #expect(throws: DuckDuckGoManagedStateStoreError.invalidSession) {
      try store.save(marker(identifier: fixedIdentifier), for: session)
    }
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    #expect(
      !FileManager.default.fileExists(
        atPath: redirectTarget.appending(path: fixedIdentifier.uuidString)
          .appending(path: "Process.json").path
      )
    )
  }

  @Test func removalRejectsStoreRootReplacedBySymlink() throws {
    let root = temporaryRoot()
    let originalRoot = temporaryRoot()
    let redirectTarget = temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: originalRoot)
      try? FileManager.default.removeItem(at: redirectTarget)
    }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try store.prepareHome(identifier: fixedIdentifier)
    try replaceStoreRoot(
      root,
      originalRoot: originalRoot,
      redirectTarget: redirectTarget,
      identifier: fixedIdentifier
    )
    let redirectedSession = redirectTarget.appending(path: fixedIdentifier.uuidString)
    let sentinel = redirectedSession.appending(path: "keep")

    #expect(throws: DuckDuckGoManagedStateStoreError.invalidSession) {
      try store.removeSession(identifier: session.identifier)
    }
    #expect(FileManager.default.fileExists(atPath: redirectedSession.path))
    #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
  }

  @Test func recordsIgnoreUnsafeAndInvalidEntriesWithoutDeletingThem() throws {
    let root = temporaryRoot()
    let symlinkTarget = temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: symlinkTarget)
    }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let validSession = try store.prepareHome(identifier: fixedIdentifier)
    let validMarker = marker(identifier: fixedIdentifier)
    try store.save(validMarker, for: validSession)

    let ignoredNames = [
      ".hidden",
      "not-a-uuid",
      "11111111-2222-3333-4444-555555555555",
      "22222222-3333-4444-5555-666666666666",
      "33333333-4444-5555-6666-777777777777",
    ]
    for name in ignoredNames {
      try FileManager.default.createDirectory(
        at: root.appending(path: name),
        withIntermediateDirectories: true
      )
    }
    try Data("not json".utf8).write(
      to: root.appending(path: ignoredNames[2]).appending(path: "Process.json")
    )
    try markerData(identifier: UUID(uuidString: ignoredNames[3])!, schemaVersion: 2)
      .write(to: root.appending(path: ignoredNames[3]).appending(path: "Process.json"))
    try markerData(identifier: UUID(), schemaVersion: 1)
      .write(to: root.appending(path: ignoredNames[4]).appending(path: "Process.json"))
    let symlinkName = "44444444-5555-6666-7777-888888888888"
    let symlinkURL = root.appending(path: symlinkName)
    try FileManager.default.createSymbolicLink(
      at: symlinkURL,
      withDestinationURL: symlinkTarget
    )

    #expect(
      try store.records()
        == [DuckDuckGoManagedSessionRecord(session: validSession, marker: validMarker)]
    )
    for name in ignoredNames {
      #expect(FileManager.default.fileExists(atPath: root.appending(path: name).path))
    }
    #expect(try symbolicLinkExists(at: symlinkURL))
  }

  @Test func recordsIgnoreMarkerSymlinkWithoutDeletingIt() throws {
    let root = temporaryRoot()
    let externalMarker = root.deletingLastPathComponent()
      .appending(path: "PickViaExternalMarker-\(UUID()).json")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: externalMarker)
    }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try store.prepareHome(identifier: fixedIdentifier)
    try markerData(identifier: fixedIdentifier, schemaVersion: 1)
      .write(to: externalMarker)
    try FileManager.default.createSymbolicLink(
      at: session.markerURL,
      withDestinationURL: externalMarker
    )

    #expect(try store.records().isEmpty)
    #expect(try symbolicLinkExists(at: session.markerURL))
    #expect(FileManager.default.fileExists(atPath: externalMarker.path))
  }

  @Test func removalCanTargetOnlyGeneratedUUIDChild() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try store.prepareHome(identifier: fixedIdentifier)
    let neighbor = root.deletingLastPathComponent().appending(path: "keep-\(UUID())")
    try Data("keep".utf8).write(to: neighbor)
    defer { try? FileManager.default.removeItem(at: neighbor) }

    try store.removeSession(identifier: session.identifier)

    #expect(!FileManager.default.fileExists(atPath: session.sessionDirectory.path))
    #expect(FileManager.default.fileExists(atPath: neighbor.path))
  }

  @Test func removalStaysBoundToOpenedRootWhenRootPathIsSwapped() throws {
    let root = temporaryRoot()
    let openedRoot = temporaryRoot()
    let redirectRoot = temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: openedRoot)
      try? FileManager.default.removeItem(at: redirectRoot)
    }
    try FileManager.default.createDirectory(
      at: redirectRoot.appending(path: fixedIdentifier.uuidString),
      withIntermediateDirectories: true
    )
    let redirectSentinel = redirectRoot.appending(path: fixedIdentifier.uuidString)
      .appending(path: "keep")
    try Data("redirect keep".utf8).write(to: redirectSentinel)
    let store = DuckDuckGoManagedStateStore(
      rootDirectory: root,
      removalDidOpenRoot: {
        try FileManager.default.moveItem(at: root, to: openedRoot)
        try FileManager.default.createSymbolicLink(
          at: root,
          withDestinationURL: redirectRoot
        )
      }
    )
    _ = try store.prepareHome(identifier: fixedIdentifier)

    try store.removeSession(identifier: fixedIdentifier)

    #expect(
      !FileManager.default.fileExists(
        atPath: openedRoot.appending(path: fixedIdentifier.uuidString).path
      )
    )
    #expect(try Data(contentsOf: redirectSentinel) == Data("redirect keep".utf8))
    #expect(try symbolicLinkExists(at: root))
  }

  @Test func sessionRemovalRejectsSessionSwappedBetweenStatAndOpen() throws {
    let root = temporaryRoot()
    let movedOriginal = temporaryRoot()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: movedOriginal)
    }
    let initialStore = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try initialStore.prepareHome(identifier: fixedIdentifier)
    let originalSentinel = session.homeDirectory.appending(path: "original-keep")
    try Data("original keep".utf8).write(to: originalSentinel)
    let replacementSentinel = session.sessionDirectory.appending(path: "replacement-keep")
    let swappingStore = DuckDuckGoManagedStateStore(
      rootDirectory: root,
      removalWillOpenSession: {
        try FileManager.default.moveItem(
          at: session.sessionDirectory,
          to: movedOriginal
        )
        try FileManager.default.createDirectory(
          at: session.sessionDirectory,
          withIntermediateDirectories: false
        )
        try Data("replacement keep".utf8).write(to: replacementSentinel)
      }
    )

    #expect(throws: DuckDuckGoManagedStateStoreError.invalidSession) {
      try swappingStore.removeSession(identifier: fixedIdentifier)
    }

    #expect(
      try Data(
        contentsOf: movedOriginal.appending(path: "Home/original-keep")
      ) == Data("original keep".utf8)
    )
    #expect(try Data(contentsOf: replacementSentinel) == Data("replacement keep".utf8))
  }

  @Test func failedDescriptorRelativeDeletionRestoresCanonicalSessionForRetry() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let initialStore = DuckDuckGoManagedStateStore(rootDirectory: root)
    let session = try initialStore.prepareHome(identifier: fixedIdentifier)
    try initialStore.saveQuarantine(
      quarantineMarker(identifier: fixedIdentifier, launchDate: Date()),
      for: session
    )
    let failingStore = DuckDuckGoManagedStateStore(
      rootDirectory: root,
      removalWillDeleteEntry: { name in
        if name == "Home" { throw TestError.injectedRemovalFailure }
      }
    )

    #expect(throws: TestError.injectedRemovalFailure) {
      try failingStore.removeSession(identifier: fixedIdentifier)
    }

    #expect(FileManager.default.fileExists(atPath: session.sessionDirectory.path))
    #expect(try initialStore.quarantineRecords().map(\.session.identifier) == [fixedIdentifier])
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
        !$0.hasPrefix(".deleting-")
      }
    )

    try initialStore.removeSession(identifier: fixedIdentifier)
    #expect(!FileManager.default.fileExists(atPath: session.sessionDirectory.path))
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "PickViaManagedStateTests-\(UUID())", directoryHint: .isDirectory)
  }

  private func marker(identifier: UUID) -> DuckDuckGoManagedProcessMarker {
    DuckDuckGoManagedProcessMarker(
      identifier: identifier,
      processIdentifier: 4321,
      launchDate: Date(timeIntervalSince1970: 1234),
      applicationPath: "/Applications/DuckDuckGo.app",
      executablePath: "/Applications/DuckDuckGo.app/Contents/MacOS/DuckDuckGo"
    )
  }

  private func quarantineMarker(
    identifier: UUID,
    launchDate: Date?
  ) -> DuckDuckGoLaunchQuarantineMarker {
    DuckDuckGoLaunchQuarantineMarker(
      identifier: identifier,
      processIdentifier: 4321,
      launchDate: launchDate,
      applicationPath: "/Applications/DuckDuckGo.app",
      executablePath: "/Applications/DuckDuckGo.app/Contents/MacOS/DuckDuckGo"
    )
  }

  private func markerData(identifier: UUID, schemaVersion: Int) throws -> Data {
    let marker: [String: Any] = [
      "schemaVersion": schemaVersion,
      "identifier": identifier.uuidString,
      "processIdentifier": 4321,
      "launchDate": 1234,
      "applicationPath": "/Applications/DuckDuckGo.app",
      "executablePath": "/Applications/DuckDuckGo.app/Contents/MacOS/DuckDuckGo",
    ]
    return try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
  }

  private func quarantineData(identifier: UUID, schemaVersion: Int) throws -> Data {
    let marker: [String: Any] = [
      "schemaVersion": schemaVersion,
      "identifier": identifier.uuidString,
      "processIdentifier": 4321,
      "applicationPath": "/Applications/DuckDuckGo.app",
      "executablePath": "/Applications/DuckDuckGo.app/Contents/MacOS/DuckDuckGo",
    ]
    return try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
  }

  private func replaceStoreRoot(
    _ root: URL,
    originalRoot: URL,
    redirectTarget: URL,
    identifier: UUID
  ) throws {
    try FileManager.default.moveItem(at: root, to: originalRoot)
    let redirectedSession = redirectTarget.appending(path: identifier.uuidString)
    try FileManager.default.createDirectory(
      at: redirectedSession,
      withIntermediateDirectories: true
    )
    try Data("keep".utf8).write(to: redirectedSession.appending(path: "keep"))
    try FileManager.default.createSymbolicLink(
      at: root,
      withDestinationURL: redirectTarget
    )
  }

  private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int) & 0o777
  }

  private func symbolicLinkExists(at url: URL) throws -> Bool {
    try FileManager.default.attributesOfItem(atPath: url.path)[.type]
      as? FileAttributeType == .typeSymbolicLink
  }

  private func orderedRanges(of keys: [String], in text: String) -> Bool {
    let starts = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
    return starts.count == keys.count && zip(starts, starts.dropFirst()).allSatisfy(<)
  }
}

private enum TestError: Error {
  case injectedRemovalFailure
}
