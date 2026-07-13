import Foundation

public enum ProfileBookmarkCreationError: Error, Equatable, Sendable {
  case persistenceUnavailable
  case creationFailed
}

public struct ResolvedProfileBookmark: Equatable, Sendable {
  public let root: URL
  public let isStale: Bool

  public init(root: URL, isStale: Bool) {
    self.root = root
    self.isStale = isStale
  }
}

public protocol ProfileBookmarkCoding: Sendable {
  func makeReadOnlyBookmark(for root: URL) throws -> Data
  func resolve(_ bookmark: Data) throws -> ResolvedProfileBookmark
}

public struct FoundationProfileBookmarkCodec: ProfileBookmarkCoding, Sendable {
  public init() {}

  public func makeReadOnlyBookmark(for root: URL) throws -> Data {
    do {
      return try root.bookmarkData(
        options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    } catch let error as CocoaError
      where error.code == .fileReadNoPermission || error.code == .fileWriteNoPermission
    {
      throw ProfileBookmarkCreationError.persistenceUnavailable
    } catch {
      throw ProfileBookmarkCreationError.creationFailed
    }
  }

  public func resolve(_ bookmark: Data) throws -> ResolvedProfileBookmark {
    var isStale = false
    let root = try URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    return ResolvedProfileBookmark(root: root, isStale: isStale)
  }
}

public protocol SecurityScopedResourceAccessing: Sendable {
  func startAccessing(_ url: URL) -> Bool
  func stopAccessing(_ url: URL)
}

public struct FoundationSecurityScopedResourceAccess: SecurityScopedResourceAccessing, Sendable {
  public init() {}

  public func startAccessing(_ url: URL) -> Bool {
    url.startAccessingSecurityScopedResource()
  }

  public func stopAccessing(_ url: URL) {
    url.stopAccessingSecurityScopedResource()
  }
}

public enum ProfileGrantPersistence: Equatable, Sendable {
  case persistent
  case currentSessionOnly
}

public enum ProfileRootAccessState: Equatable, Sendable {
  case missing
  case granted
  case revoked
}

public struct ProfileRootAccessResult: Sendable {
  public let state: ProfileRootAccessState
  public let lease: ProfileRootLease?

  public init(state: ProfileRootAccessState, lease: ProfileRootLease?) {
    self.state = state
    self.lease = lease
  }
}

public protocol ProfileRootAccessProviding: Sendable {
  func beginAccess(for bundleIdentifier: String) -> ProfileRootAccessResult
}

public protocol ProfileAccessManaging: ProfileRootAccessProviding {
  func installGrant(root: URL, for bundleIdentifier: String) throws -> ProfileGrantPersistence
  func persistence(for bundleIdentifier: String) -> ProfileGrantPersistence?
  func removeGrant(for bundleIdentifier: String) throws
}

public enum ProfileAccessManagementError: Error, Equatable, Sendable {
  case unavailable
}

public struct MissingProfileAccessManager: ProfileAccessManaging, Sendable {
  public init() {}

  public func beginAccess(for bundleIdentifier: String) -> ProfileRootAccessResult {
    ProfileRootAccessResult(state: .missing, lease: nil)
  }

  public func installGrant(
    root: URL,
    for bundleIdentifier: String
  ) throws -> ProfileGrantPersistence {
    throw ProfileAccessManagementError.unavailable
  }

  public func persistence(for bundleIdentifier: String) -> ProfileGrantPersistence? {
    nil
  }

  public func removeGrant(for bundleIdentifier: String) throws {}
}

public final class ProfileRootLease: @unchecked Sendable {
  public let root: URL
  private let lock = NSLock()
  private var stopAction: (@Sendable () -> Void)?

  public init(root: URL, stopAction: @escaping @Sendable () -> Void) {
    self.root = root
    self.stopAction = stopAction
  }

  public func end() {
    let action = lock.withLock {
      let action = stopAction
      stopAction = nil
      return action
    }
    action?()
  }

  deinit {
    end()
  }
}

public final class ProfileAccessCoordinator: ProfileAccessManaging, @unchecked Sendable {
  private let store: any ProfileAccessStoring
  private let bookmarkCodec: any ProfileBookmarkCoding
  private let resourceAccess: any SecurityScopedResourceAccessing
  private let lock = NSLock()
  private var sessionRoots: [String: URL] = [:]

  public init(
    store: any ProfileAccessStoring,
    bookmarkCodec: any ProfileBookmarkCoding = FoundationProfileBookmarkCodec(),
    resourceAccess: any SecurityScopedResourceAccessing = FoundationSecurityScopedResourceAccess()
  ) {
    self.store = store
    self.bookmarkCodec = bookmarkCodec
    self.resourceAccess = resourceAccess
  }

  public func installGrant(
    root: URL,
    for bundleIdentifier: String
  ) throws -> ProfileGrantPersistence {
    let bookmark: Data
    do {
      bookmark = try bookmarkCodec.makeReadOnlyBookmark(for: root)
    } catch ProfileBookmarkCreationError.persistenceUnavailable {
      if try store.bookmark(for: bundleIdentifier) != nil {
        throw ProfileBookmarkCreationError.persistenceUnavailable
      }
      lock.withLock { sessionRoots[bundleIdentifier] = root }
      return .currentSessionOnly
    }

    try store.save(bookmark, for: bundleIdentifier)
    lock.withLock { sessionRoots[bundleIdentifier] = root }
    return .persistent
  }

  public func persistence(for bundleIdentifier: String) -> ProfileGrantPersistence? {
    if (try? store.bookmark(for: bundleIdentifier)) != nil {
      return .persistent
    }
    return lock.withLock {
      sessionRoots[bundleIdentifier] == nil ? nil : .currentSessionOnly
    }
  }

  public func beginAccess(for bundleIdentifier: String) -> ProfileRootAccessResult {
    let bookmark: Data?
    do {
      bookmark = try store.bookmark(for: bundleIdentifier)
    } catch {
      return ProfileRootAccessResult(state: .revoked, lease: nil)
    }

    if let bookmark {
      return beginPersistentAccess(bookmark: bookmark, bundleIdentifier: bundleIdentifier)
    }

    guard let root = lock.withLock({ sessionRoots[bundleIdentifier] }) else {
      return ProfileRootAccessResult(state: .missing, lease: nil)
    }
    let didStart = resourceAccess.startAccessing(root)
    return ProfileRootAccessResult(
      state: .granted,
      lease: makeLease(root: root, stopsScopedAccess: didStart)
    )
  }

  public func removeGrant(for bundleIdentifier: String) throws {
    try store.remove(for: bundleIdentifier)
    _ = lock.withLock { sessionRoots.removeValue(forKey: bundleIdentifier) }
  }

  private func beginPersistentAccess(
    bookmark: Data,
    bundleIdentifier: String
  ) -> ProfileRootAccessResult {
    do {
      let resolved = try bookmarkCodec.resolve(bookmark)
      if resolved.isStale {
        let refreshed = try bookmarkCodec.makeReadOnlyBookmark(for: resolved.root)
        try store.save(refreshed, for: bundleIdentifier)
      }
      guard resourceAccess.startAccessing(resolved.root) else {
        return ProfileRootAccessResult(state: .revoked, lease: nil)
      }
      return ProfileRootAccessResult(
        state: .granted,
        lease: makeLease(root: resolved.root, stopsScopedAccess: true)
      )
    } catch {
      return ProfileRootAccessResult(state: .revoked, lease: nil)
    }
  }

  private func makeLease(root: URL, stopsScopedAccess: Bool) -> ProfileRootLease {
    let resourceAccess = resourceAccess
    return ProfileRootLease(root: root) {
      if stopsScopedAccess {
        resourceAccess.stopAccessing(root)
      }
    }
  }
}
