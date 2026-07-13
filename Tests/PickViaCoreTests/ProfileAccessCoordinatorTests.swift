import Foundation
import Testing

@testable import PickViaCore

@Suite("Profile access coordinator")
struct ProfileAccessCoordinatorTests {
  @Test func missingGrantReturnsMissingWithoutLease() {
    let harness = CoordinatorHarness.missing()

    let result = harness.coordinator.beginAccess(for: chromeBundleIdentifier)

    #expect(result.state == .missing)
    #expect(result.lease == nil)
    #expect(harness.scope.started.isEmpty)
  }

  @Test func resolvedBookmarkStartsScopedAccessAndReturnsLease() throws {
    let root = URL(fileURLWithPath: "/Chrome")
    let harness = CoordinatorHarness.resolved(root: root)

    let result = harness.coordinator.beginAccess(for: chromeBundleIdentifier)
    let lease = try #require(result.lease)
    defer { lease.end() }

    #expect(result.state == .granted)
    #expect(lease.root == root)
    #expect(harness.scope.started == [root])
  }

  @Test func failedBookmarkResolutionReturnsRevoked() {
    let harness = CoordinatorHarness.resolutionFailed()

    let result = harness.coordinator.beginAccess(for: chromeBundleIdentifier)

    #expect(result.state == .revoked)
    #expect(result.lease == nil)
    #expect(harness.scope.started.isEmpty)
  }

  @Test func failedScopedAccessStartReturnsRevokedWithoutStopping() {
    let harness = CoordinatorHarness.resolved(root: URL(fileURLWithPath: "/Chrome"))
    harness.scope.startResult = false

    let result = harness.coordinator.beginAccess(for: chromeBundleIdentifier)

    #expect(result.state == .revoked)
    #expect(result.lease == nil)
    #expect(harness.scope.stopped.isEmpty)
  }

  @Test func staleBookmarkIsRefreshedBeforeReturningLease() throws {
    let root = URL(fileURLWithPath: "/Chrome")
    let harness = CoordinatorHarness.stale(root: root)

    let result = harness.coordinator.beginAccess(for: chromeBundleIdentifier)
    let lease = try #require(result.lease)
    defer { lease.end() }

    #expect(harness.store.saved.count == 1)
    #expect(harness.store.saved.first?.bundleIdentifier == chromeBundleIdentifier)
    #expect(harness.store.saved.first?.bookmark == Data("refreshed".utf8))
    #expect(result.state == .granted)
  }

  @Test func successfulOperationStopsScopedAccessExactlyOnce() throws {
    let root = URL(fileURLWithPath: "/Chrome")
    let harness = CoordinatorHarness.resolved(root: root)
    let lease = try #require(harness.coordinator.beginAccess(for: chromeBundleIdentifier).lease)

    defer { lease.end() }
    lease.end()

    #expect(harness.scope.started == [root])
    #expect(harness.scope.stopped == [root])
  }

  @Test func thrownOperationStillStopsScopedAccessExactlyOnce() throws {
    let root = URL(fileURLWithPath: "/Chrome")
    let harness = CoordinatorHarness.resolved(root: root)
    let lease = try #require(harness.coordinator.beginAccess(for: chromeBundleIdentifier).lease)

    #expect(throws: ProbeError.failed) {
      defer { lease.end() }
      throw ProbeError.failed
    }

    #expect(harness.scope.started == [root])
    #expect(harness.scope.stopped == [root])
  }

  @Test func earlyReturnStillStopsScopedAccessExactlyOnce() throws {
    let root = URL(fileURLWithPath: "/Chrome")
    let harness = CoordinatorHarness.resolved(root: root)

    exerciseEarlyReturn(harness.coordinator.beginAccess(for: chromeBundleIdentifier))

    #expect(harness.scope.started == [root])
    #expect(harness.scope.stopped == [root])
  }

  @Test func leaseDeinitializationStopsScopedAccessAsSafetyNet() throws {
    let root = URL(fileURLWithPath: "/Chrome")
    let harness = CoordinatorHarness.resolved(root: root)

    _ = try #require(harness.coordinator.beginAccess(for: chromeBundleIdentifier).lease)

    #expect(harness.scope.stopped == [root])
  }

  @Test func persistentGrantIsSavedBeforeItIsPublishedForTheSession() throws {
    let root = URL(fileURLWithPath: "/Chrome")
    let harness = CoordinatorHarness.missing()
    harness.codec.madeBookmark = Data("persistent".utf8)

    let persistence = try harness.coordinator.installGrant(
      root: root,
      for: chromeBundleIdentifier
    )

    #expect(persistence == .persistent)
    #expect(harness.codec.madeRoots == [root])
    #expect(harness.store.saved == [
      StoredBookmark(bundleIdentifier: chromeBundleIdentifier, bookmark: Data("persistent".utf8))
    ])
    #expect(harness.coordinator.persistence(for: chromeBundleIdentifier) == .persistent)
  }

  @Test func failedPersistentSaveDoesNotPublishSessionRoot() {
    let harness = CoordinatorHarness.missing()
    harness.codec.madeBookmark = Data("persistent".utf8)
    harness.store.saveError = ProbeError.failed

    #expect(throws: ProbeError.failed) {
      try harness.coordinator.installGrant(
        root: URL(fileURLWithPath: "/Chrome"),
        for: chromeBundleIdentifier
      )
    }
    #expect(harness.coordinator.persistence(for: chromeBundleIdentifier) == nil)
    #expect(harness.coordinator.beginAccess(for: chromeBundleIdentifier).state == .missing)
  }

  @Test func signingLimitedBookmarkCreationRetainsCurrentSessionAccess() throws {
    let root = URL(fileURLWithPath: "/Chrome")
    let harness = CoordinatorHarness.missing()
    harness.codec.makeError = ProfileBookmarkCreationError.persistenceUnavailable
    harness.scope.startResult = false

    let persistence = try harness.coordinator.installGrant(
      root: root,
      for: chromeBundleIdentifier
    )
    let result = harness.coordinator.beginAccess(for: chromeBundleIdentifier)
    let lease = try #require(result.lease)
    lease.end()

    #expect(persistence == .currentSessionOnly)
    #expect(harness.coordinator.persistence(for: chromeBundleIdentifier) == .currentSessionOnly)
    #expect(result.state == .granted)
    #expect(lease.root == root)
    #expect(harness.store.saved.isEmpty)
    #expect(harness.scope.stopped.isEmpty)
  }

  @Test func signingLimitedReplacementLeavesPriorPersistentGrantAuthoritative() throws {
    let prior = Data("prior".utf8)
    let harness = CoordinatorHarness.resolved(
      root: URL(fileURLWithPath: "/Old"),
      bookmark: prior
    )
    harness.codec.makeError = ProfileBookmarkCreationError.persistenceUnavailable

    #expect(throws: ProfileBookmarkCreationError.persistenceUnavailable) {
      try harness.coordinator.installGrant(
        root: URL(fileURLWithPath: "/New"),
        for: chromeBundleIdentifier
      )
    }
    #expect(try harness.store.bookmark(for: chromeBundleIdentifier) == prior)
    #expect(harness.coordinator.persistence(for: chromeBundleIdentifier) == .persistent)
  }

  @Test func ordinaryBookmarkCreationFailureDoesNotInstallSessionGrant() {
    let harness = CoordinatorHarness.missing()
    harness.codec.makeError = ProfileBookmarkCreationError.creationFailed

    #expect(throws: ProfileBookmarkCreationError.creationFailed) {
      try harness.coordinator.installGrant(
        root: URL(fileURLWithPath: "/Chrome"),
        for: chromeBundleIdentifier
      )
    }
    #expect(harness.coordinator.persistence(for: chromeBundleIdentifier) == nil)
  }

  @Test func removeGrantDeletesPersistentAndCurrentSessionAccess() throws {
    let root = URL(fileURLWithPath: "/Chrome")
    let harness = CoordinatorHarness.missing()
    harness.codec.makeError = ProfileBookmarkCreationError.persistenceUnavailable
    _ = try harness.coordinator.installGrant(root: root, for: chromeBundleIdentifier)

    try harness.coordinator.removeGrant(for: chromeBundleIdentifier)

    #expect(harness.store.removed == [chromeBundleIdentifier])
    #expect(harness.coordinator.persistence(for: chromeBundleIdentifier) == nil)
    #expect(harness.coordinator.beginAccess(for: chromeBundleIdentifier).state == .missing)
  }

  @Test func concurrentRemoveWaitsForInstallStateTransition() throws {
    let harness = CoordinatorHarness.missing()
    harness.codec.madeBookmark = Data("persistent".utf8)
    let makeStarted = DispatchSemaphore(value: 0)
    let allowMake = DispatchSemaphore(value: 0)
    let removeEnteredStore = DispatchSemaphore(value: 0)
    harness.codec.makeStarted = makeStarted
    harness.codec.allowMake = allowMake
    harness.store.removeStarted = removeEnteredStore
    let coordinator = harness.coordinator

    let errors = CoordinatorErrorRecorder()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      do {
        _ = try coordinator.installGrant(
          root: URL(fileURLWithPath: "/Chrome"),
          for: chromeBundleIdentifier
        )
      } catch {
        errors.record(error)
      }
    }
    #expect(makeStarted.wait(timeout: .now() + 2) == .success)

    let removeStarted = DispatchSemaphore(value: 0)
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      removeStarted.signal()
      do {
        try coordinator.removeGrant(for: chromeBundleIdentifier)
      } catch {
        errors.record(error)
      }
    }
    #expect(removeStarted.wait(timeout: .now() + 2) == .success)
    let removeOverlappedInstall =
      removeEnteredStore.wait(timeout: .now() + 1) == .success
    allowMake.signal()

    #expect(group.wait(timeout: .now() + 5) == .success)
    #expect(!removeOverlappedInstall)
    #expect(errors.errors.isEmpty)
    #expect(coordinator.persistence(for: chromeBundleIdentifier) == nil)
  }

  @Test func missingManagerReportsUnavailableWithoutSideEffects() {
    let manager = MissingProfileAccessManager()

    #expect(manager.beginAccess(for: chromeBundleIdentifier).state == .missing)
    #expect(manager.persistence(for: chromeBundleIdentifier) == nil)
    #expect(throws: ProfileAccessManagementError.unavailable) {
      try manager.installGrant(
        root: URL(fileURLWithPath: "/Chrome"),
        for: chromeBundleIdentifier
      )
    }
    #expect(throws: Never.self) {
      try manager.removeGrant(for: chromeBundleIdentifier)
    }
  }

  private func exerciseEarlyReturn(_ result: ProfileRootAccessResult) {
    guard let lease = result.lease else { return }
    defer { lease.end() }
    return
  }
}

private let chromeBundleIdentifier = "com.google.Chrome"

private enum ProbeError: Error, Equatable {
  case failed
}

private struct StoredBookmark: Equatable {
  let bundleIdentifier: String
  let bookmark: Data
}

private final class CoordinatorHarness {
  let store: ProfileAccessStoreSpy
  let codec: ProfileBookmarkCodecSpy
  let scope: SecurityScopedResourceSpy
  let coordinator: ProfileAccessCoordinator

  init(
    store: ProfileAccessStoreSpy,
    codec: ProfileBookmarkCodecSpy,
    scope: SecurityScopedResourceSpy
  ) {
    self.store = store
    self.codec = codec
    self.scope = scope
    coordinator = ProfileAccessCoordinator(store: store, bookmarkCodec: codec, resourceAccess: scope)
  }

  static func missing() -> CoordinatorHarness {
    CoordinatorHarness(
      store: ProfileAccessStoreSpy(),
      codec: ProfileBookmarkCodecSpy(),
      scope: SecurityScopedResourceSpy()
    )
  }

  static func resolved(
    root: URL,
    bookmark: Data = Data("bookmark".utf8)
  ) -> CoordinatorHarness {
    let store = ProfileAccessStoreSpy(bookmarks: [chromeBundleIdentifier: bookmark])
    let codec = ProfileBookmarkCodecSpy()
    codec.resolvedBookmark = ResolvedProfileBookmark(root: root, isStale: false)
    return CoordinatorHarness(store: store, codec: codec, scope: SecurityScopedResourceSpy())
  }

  static func stale(root: URL) -> CoordinatorHarness {
    let harness = resolved(root: root)
    harness.codec.resolvedBookmark = ResolvedProfileBookmark(root: root, isStale: true)
    harness.codec.madeBookmark = Data("refreshed".utf8)
    return harness
  }

  static func resolutionFailed() -> CoordinatorHarness {
    let harness = resolved(root: URL(fileURLWithPath: "/Chrome"))
    harness.codec.resolveError = ProbeError.failed
    return harness
  }
}

private final class ProfileAccessStoreSpy: ProfileAccessStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var bookmarks: [String: Data]
  private var recordedSaved: [StoredBookmark] = []
  private var recordedRemoved: [String] = []

  var bookmarkError: (any Error)?
  var saveError: (any Error)?
  var removeError: (any Error)?
  var removeStarted: DispatchSemaphore?

  init(bookmarks: [String: Data] = [:]) {
    self.bookmarks = bookmarks
  }

  var saved: [StoredBookmark] {
    lock.withLock { recordedSaved }
  }

  var removed: [String] {
    lock.withLock { recordedRemoved }
  }

  func bookmark(for bundleIdentifier: String) throws -> Data? {
    try lock.withLock {
      if let bookmarkError { throw bookmarkError }
      return bookmarks[bundleIdentifier]
    }
  }

  func save(_ bookmark: Data, for bundleIdentifier: String) throws {
    try lock.withLock {
      if let saveError { throw saveError }
      bookmarks[bundleIdentifier] = bookmark
      recordedSaved.append(StoredBookmark(bundleIdentifier: bundleIdentifier, bookmark: bookmark))
    }
  }

  func remove(for bundleIdentifier: String) throws {
    removeStarted?.signal()
    try lock.withLock {
      if let removeError { throw removeError }
      bookmarks.removeValue(forKey: bundleIdentifier)
      recordedRemoved.append(bundleIdentifier)
    }
  }
}

private final class ProfileBookmarkCodecSpy: ProfileBookmarkCoding, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedMadeRoots: [URL] = []

  var madeBookmark = Data("made".utf8)
  var makeError: (any Error)?
  var resolvedBookmark = ResolvedProfileBookmark(
    root: URL(fileURLWithPath: "/resolved"),
    isStale: false
  )
  var resolveError: (any Error)?
  var makeStarted: DispatchSemaphore?
  var allowMake: DispatchSemaphore?

  var madeRoots: [URL] {
    lock.withLock { recordedMadeRoots }
  }

  func makeReadOnlyBookmark(for root: URL) throws -> Data {
    let result: (Data, (any Error)?, DispatchSemaphore?, DispatchSemaphore?) = lock.withLock {
      recordedMadeRoots.append(root)
      return (madeBookmark, makeError, makeStarted, allowMake)
    }
    result.2?.signal()
    result.3?.wait()
    if let error = result.1 { throw error }
    return result.0
  }

  func resolve(_ bookmark: Data) throws -> ResolvedProfileBookmark {
    try lock.withLock {
      if let resolveError { throw resolveError }
      return resolvedBookmark
    }
  }
}

private final class CoordinatorErrorRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedErrors: [any Error] = []

  var errors: [any Error] {
    lock.withLock { recordedErrors }
  }

  func record(_ error: any Error) {
    lock.withLock { recordedErrors.append(error) }
  }
}

private final class SecurityScopedResourceSpy: SecurityScopedResourceAccessing, @unchecked Sendable {
  private let lock = NSLock()
  private var recordedStarted: [URL] = []
  private var recordedStopped: [URL] = []

  var startResult = true

  var started: [URL] {
    lock.withLock { recordedStarted }
  }

  var stopped: [URL] {
    lock.withLock { recordedStopped }
  }

  func startAccessing(_ url: URL) -> Bool {
    lock.withLock {
      recordedStarted.append(url)
      return startResult
    }
  }

  func stopAccessing(_ url: URL) {
    lock.withLock { recordedStopped.append(url) }
  }
}
