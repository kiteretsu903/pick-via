import Foundation
import OSLog

public protocol DuckDuckGoRouting: Sendable {
  func open(
    url: URL,
    applicationURL: URL,
    mode: BrowserMode
  ) async throws
}

enum DuckDuckGoRoutingError: Error, Equatable, Sendable {
  case unsupportedBuild
  case fireUnavailable
  case processIdentityMismatch
  case readinessTimeout
  case activationFailed
}

public actor DuckDuckGoProcessCoordinator: DuckDuckGoRouting {
  private enum ManagedIdentityEvaluation {
    case confirmed
    case ambiguous
    case stale
  }

  private struct LiveManagedProcess: Sendable {
    let record: DuckDuckGoManagedSessionRecord
    let snapshot: DuckDuckGoApplicationSnapshot
  }

  private struct ManagedProcessInventory: Sendable {
    var confirmed: [LiveManagedProcess] = []
    var excludedProcessIdentifiers: Set<Int32> = []
  }

  private struct QuarantinedLaunch: Sendable {
    let session: DuckDuckGoManagedSession
    let marker: DuckDuckGoLaunchQuarantineMarker
  }

  private struct StartupCleanupResult: Sendable {
    let liveQuarantines: [DuckDuckGoLaunchQuarantineRecord]
  }

  private let compatibilityChecker: any DuckDuckGoBuildCompatibilityChecking
  private let applications: any DuckDuckGoApplicationManaging
  private let events: any DuckDuckGoAppleEventSending
  private let stateStore: any DuckDuckGoManagedStateStoring
  private let rollbackExitTimeout: Duration
  private let logger = Logger(
    subsystem: "com.pickvia.app",
    category: "DuckDuckGoRouting"
  )
  private var routeIsInProgress = false
  private var routeWaiters: [CheckedContinuation<Void, Never>] = []
  private var quarantinedLaunches: [Int32: QuarantinedLaunch] = [:]
  private var startupCleanupTask: Task<StartupCleanupResult, any Error>?

  public init() {
    let applications = SystemDuckDuckGoApplicationManager()
    let stateStore = DuckDuckGoManagedStateStore()
    compatibilityChecker = DuckDuckGoBuildCompatibilityChecker()
    self.applications = applications
    events = SystemDuckDuckGoAppleEventSender()
    self.stateStore = stateStore
    rollbackExitTimeout = .seconds(5)
    startupCleanupTask = Task.detached {
      try await Self.performStartupCleanup(
        applications: applications,
        stateStore: stateStore
      )
    }
  }

  init(
    compatibilityChecker: any DuckDuckGoBuildCompatibilityChecking =
      DuckDuckGoBuildCompatibilityChecker(),
    applications: any DuckDuckGoApplicationManaging =
      SystemDuckDuckGoApplicationManager(),
    events: any DuckDuckGoAppleEventSending =
      SystemDuckDuckGoAppleEventSender(),
    stateStore: any DuckDuckGoManagedStateStoring =
      DuckDuckGoManagedStateStore(),
    rollbackExitTimeout: Duration = .seconds(5),
    startsStartupCleanup: Bool = false
  ) {
    self.compatibilityChecker = compatibilityChecker
    self.applications = applications
    self.events = events
    self.stateStore = stateStore
    self.rollbackExitTimeout = rollbackExitTimeout
    if startsStartupCleanup {
      startupCleanupTask = Task.detached {
        try await Self.performStartupCleanup(
          applications: applications,
          stateStore: stateStore
        )
      }
    } else {
      startupCleanupTask = nil
    }
  }

  public func open(
    url: URL,
    applicationURL: URL,
    mode: BrowserMode
  ) async throws {
    await acquireRoute()
    defer { releaseRoute() }
    try Task.checkCancellation()
    try await waitForStartupCleanup()
    try Task.checkCancellation()
    try await openSerially(url: url, applicationURL: applicationURL, mode: mode)
  }

  func waitForStartupCleanup() async throws {
    guard let startupCleanupTask else { return }
    let result = try await startupCleanupTask.value
    self.startupCleanupTask = nil
    for record in result.liveQuarantines {
      quarantinedLaunches[record.marker.processIdentifier] = QuarantinedLaunch(
        session: record.session,
        marker: record.marker
      )
    }
  }

  private func openSerially(
    url: URL,
    applicationURL: URL,
    mode: BrowserMode
  ) async throws {
    try await reconcileQuarantinedLaunches()
    let trustedApplicationURL = Self.canonicalFileURL(applicationURL)
    let expectedExecutableURL = Self.canonicalFileURL(
      trustedApplicationURL.appending(path: "Contents/MacOS/DuckDuckGo")
    )

    switch compatibilityChecker.compatibility(of: trustedApplicationURL) {
    case .unsupported:
      throw DuckDuckGoRoutingError.unsupportedBuild
    case .ordinaryOnly where mode == .private:
      throw DuckDuckGoRoutingError.fireUnavailable
    case .ordinaryOnly, .fire:
      break
    }

    var managed = try await managedProcessInventory()
    managed.excludedProcessIdentifiers.formUnion(quarantinedLaunches.keys)
    try Task.checkCancellation()

    switch mode {
    case .normal:
      try await openOrdinary(
        url: url,
        applicationURL: trustedApplicationURL,
        executableURL: expectedExecutableURL,
        excluding: managed.excludedProcessIdentifiers
      )
    case .private:
      let reusable = managed.confirmed.filter {
        !quarantinedLaunches.keys.contains($0.snapshot.processIdentifier)
          && Self.markerMatchesApplication(
            $0.record.marker,
            applicationURL: trustedApplicationURL,
            executableURL: expectedExecutableURL
          )
      }
      if let existing = Self.newestLiveManaged(reusable) {
        try await reuseFireProcess(existing, url: url)
      } else {
        try await launchFire(
          url: url,
          applicationURL: trustedApplicationURL,
          executableURL: expectedExecutableURL
        )
      }
    }
  }

  private func acquireRoute() async {
    guard routeIsInProgress else {
      routeIsInProgress = true
      return
    }
    await withCheckedContinuation { continuation in
      routeWaiters.append(continuation)
    }
  }

  private func releaseRoute() {
    guard !routeWaiters.isEmpty else {
      routeIsInProgress = false
      return
    }
    routeWaiters.removeFirst().resume()
  }

  private func managedProcessInventory() async throws -> ManagedProcessInventory {
    let records = try stateStore.records()
    var inventory = ManagedProcessInventory()
    for record in records {
      let snapshot = await applications.snapshot(
        processIdentifier: record.marker.processIdentifier
      )
      switch Self.evaluateManagedIdentity(snapshot, marker: record.marker) {
      case .confirmed:
        guard let snapshot else { continue }
        inventory.confirmed.append(
          LiveManagedProcess(record: record, snapshot: snapshot)
        )
        inventory.excludedProcessIdentifiers.insert(record.marker.processIdentifier)
      case .ambiguous:
        inventory.excludedProcessIdentifiers.insert(record.marker.processIdentifier)
      case .stale:
        try Task.checkCancellation()
        try stateStore.removeSession(identifier: record.session.identifier)
      }
    }
    return inventory
  }

  private func openOrdinary(
    url: URL,
    applicationURL: URL,
    executableURL: URL,
    excluding managedProcessIdentifiers: Set<Int32>
  ) async throws {
    let running = await applications.runningApplications(
      bundleIdentifier: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier
    )
    let existing =
      running
      .filter {
        !managedProcessIdentifiers.contains($0.processIdentifier)
          && Self.matchesApplicationIdentity(
            $0,
            applicationURL: applicationURL,
            executableURL: executableURL
          )
      }
      .max { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) }

    guard let existing else {
      try Task.checkCancellation()
      _ = try await applications.launch(
        DuckDuckGoApplicationLaunchRequest(
          applicationURL: applicationURL,
          urls: [url],
          createsNewApplicationInstance: true,
          arguments: [],
          environment: [:],
          activates: true
        )
      )
      return
    }

    logger.debug(
      "Sending DuckDuckGo URL event to PID \(existing.processIdentifier, privacy: .public)"
    )
    try Task.checkCancellation()
    try await events.send(.openURL(url), processIdentifier: existing.processIdentifier)
    try Task.checkCancellation()
    guard await applications.activate(processIdentifier: existing.processIdentifier) else {
      throw DuckDuckGoRoutingError.activationFailed
    }
  }

  private func launchFire(
    url: URL,
    applicationURL: URL,
    executableURL: URL
  ) async throws {
    try Task.checkCancellation()
    let session = try stateStore.prepareHome(identifier: UUID())
    let launched: DuckDuckGoApplicationSnapshot
    do {
      try Task.checkCancellation()
      launched = try await applications.launch(
        DuckDuckGoApplicationLaunchRequest(
          applicationURL: applicationURL,
          urls: [],
          createsNewApplicationInstance: true,
          arguments: ["-ApplePersistenceIgnoreState", "YES"],
          environment: ["CFFIXED_USER_HOME": session.homeDirectory.path],
          activates: false
        )
      )
      quarantinedLaunches[launched.processIdentifier] = QuarantinedLaunch(
        session: session,
        marker: DuckDuckGoLaunchQuarantineMarker(
          identifier: session.identifier,
          processIdentifier: launched.processIdentifier,
          launchDate: launched.launchDate,
          applicationPath: applicationURL.path,
          executablePath: executableURL.path
        )
      )
    } catch {
      try? stateStore.removeSession(identifier: session.identifier)
      throw error
    }

    do {
      guard let quarantine = quarantinedLaunches[launched.processIdentifier] else {
        throw DuckDuckGoRoutingError.processIdentityMismatch
      }
      try stateStore.saveQuarantine(quarantine.marker, for: session)
    } catch {
      await rollbackFreshLaunch(launched, session: session)
      throw error
    }

    guard
      Self.matchesApplicationIdentity(
        launched,
        applicationURL: applicationURL,
        executableURL: executableURL
      ), let launchDate = launched.launchDate
    else {
      await rollbackFreshLaunch(launched, session: session)
      throw DuckDuckGoRoutingError.processIdentityMismatch
    }

    do {
      try Task.checkCancellation()
    } catch {
      await rollbackFreshLaunch(launched, session: session)
      throw error
    }

    let marker = DuckDuckGoManagedProcessMarker(
      identifier: session.identifier,
      processIdentifier: launched.processIdentifier,
      launchDate: launchDate,
      applicationPath: applicationURL.path,
      executablePath: executableURL.path
    )
    do {
      try stateStore.save(marker, for: session)
    } catch {
      await rollbackFreshLaunch(launched, session: session)
      throw error
    }
    try stateStore.removeQuarantine(for: session)
    quarantinedLaunches.removeValue(forKey: launched.processIdentifier)

    let ready: DuckDuckGoApplicationSnapshot
    do {
      ready = try await applications.waitUntilFinishedLaunching(
        processIdentifier: launched.processIdentifier,
        timeout: .seconds(5)
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw DuckDuckGoRoutingError.readinessTimeout
    }
    guard
      Self.evaluateManagedIdentity(ready, marker: marker) == .confirmed
    else {
      throw DuckDuckGoRoutingError.processIdentityMismatch
    }

    try await deliverFireURL(url, to: ready.processIdentifier)
  }

  private func deliverFireURL(_ url: URL, to processIdentifier: Int32) async throws {
    try Task.checkCancellation()
    logger.debug(
      "Sending DuckDuckGo reopen event to PID \(processIdentifier, privacy: .public)"
    )
    try await events.send(.reopen, processIdentifier: processIdentifier)
    try Task.checkCancellation()
    logger.debug(
      "Sending DuckDuckGo URL event to PID \(processIdentifier, privacy: .public)"
    )
    try await events.send(.openURL(url), processIdentifier: processIdentifier)
    try Task.checkCancellation()
    guard await applications.activate(processIdentifier: processIdentifier) else {
      throw DuckDuckGoRoutingError.activationFailed
    }
  }

  private func reuseFireProcess(
    _ process: LiveManagedProcess,
    url: URL
  ) async throws {
    var snapshot = process.snapshot
    if !snapshot.isFinishedLaunching {
      try Task.checkCancellation()
      do {
        snapshot = try await applications.waitUntilFinishedLaunching(
          processIdentifier: snapshot.processIdentifier,
          timeout: .seconds(5)
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw DuckDuckGoRoutingError.readinessTimeout
      }
      guard
        Self.evaluateManagedIdentity(snapshot, marker: process.record.marker)
          == .confirmed
      else {
        throw DuckDuckGoRoutingError.processIdentityMismatch
      }
    }
    try await deliverFireURL(url, to: snapshot.processIdentifier)
  }

  private func rollbackFreshLaunch(
    _ launched: DuckDuckGoApplicationSnapshot,
    session: DuckDuckGoManagedSession
  ) async {
    let applications = self.applications
    let stateStore = self.stateStore
    let rollbackExitTimeout = self.rollbackExitTimeout
    let didReap = await Task.detached {
      guard
        let current = await applications.snapshot(
          processIdentifier: launched.processIdentifier
        )
      else {
        return Self.removeSessionIfPossible(stateStore, identifier: session.identifier)
      }
      guard !current.isTerminated else {
        return Self.removeSessionIfPossible(stateStore, identifier: session.identifier)
      }
      guard Self.representsSameLaunch(current, as: launched) else { return false }

      _ = await applications.terminate(processIdentifier: launched.processIdentifier)
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: rollbackExitTimeout)
      while true {
        let value = await applications.snapshot(
          processIdentifier: launched.processIdentifier
        )
        if value == nil || value?.isTerminated == true {
          return Self.removeSessionIfPossible(
            stateStore,
            identifier: session.identifier
          )
        }
        guard clock.now < deadline else { return false }
        try? await clock.sleep(for: .milliseconds(50))
      }
    }.value
    if didReap {
      quarantinedLaunches.removeValue(forKey: launched.processIdentifier)
    }
  }

  private func reconcileQuarantinedLaunches() async throws {
    for record in try stateStore.quarantineRecords() {
      quarantinedLaunches[record.marker.processIdentifier] = QuarantinedLaunch(
        session: record.session,
        marker: record.marker
      )
    }

    var reapedProcessIdentifiers: [Int32] = []
    for (processIdentifier, launch) in quarantinedLaunches {
      let snapshot = await applications.snapshot(processIdentifier: processIdentifier)
      guard Self.quarantineIsStale(snapshot, marker: launch.marker) else {
        continue
      }
      try Task.checkCancellation()
      try stateStore.removeSession(identifier: launch.session.identifier)
      reapedProcessIdentifiers.append(processIdentifier)
    }
    for processIdentifier in reapedProcessIdentifiers {
      quarantinedLaunches.removeValue(forKey: processIdentifier)
    }
  }

  private static func performStartupCleanup(
    applications: any DuckDuckGoApplicationManaging,
    stateStore: any DuckDuckGoManagedStateStoring
  ) async throws -> StartupCleanupResult {
    var liveQuarantines: [DuckDuckGoLaunchQuarantineRecord] = []
    for record in try stateStore.quarantineRecords() {
      let snapshot = await applications.snapshot(
        processIdentifier: record.marker.processIdentifier
      )
      if quarantineIsStale(snapshot, marker: record.marker) {
        try stateStore.removeSession(identifier: record.session.identifier)
      } else {
        liveQuarantines.append(record)
      }
    }

    let quarantineSessionIdentifiers = Set(
      liveQuarantines.map(\.session.identifier)
    )
    for record in try stateStore.records()
    where !quarantineSessionIdentifiers.contains(record.session.identifier) {
      let snapshot = await applications.snapshot(
        processIdentifier: record.marker.processIdentifier
      )
      if evaluateManagedIdentity(snapshot, marker: record.marker) == .stale {
        try stateStore.removeSession(identifier: record.session.identifier)
      }
    }
    return StartupCleanupResult(liveQuarantines: liveQuarantines)
  }

  private static func quarantineIsStale(
    _ snapshot: DuckDuckGoApplicationSnapshot?,
    marker: DuckDuckGoLaunchQuarantineMarker
  ) -> Bool {
    guard let snapshot, !snapshot.isTerminated else { return true }
    guard let expectedLaunchDate = marker.launchDate,
      let actualLaunchDate = snapshot.launchDate
    else {
      return false
    }
    return actualLaunchDate != expectedLaunchDate
  }

  private static func newestLiveManaged(
    _ processes: [LiveManagedProcess]
  ) -> LiveManagedProcess? {
    processes.max { $0.record.marker.launchDate < $1.record.marker.launchDate }
  }

  private static func evaluateManagedIdentity(
    _ snapshot: DuckDuckGoApplicationSnapshot?,
    marker: DuckDuckGoManagedProcessMarker
  ) -> ManagedIdentityEvaluation {
    guard let snapshot, !snapshot.isTerminated else { return .stale }
    guard snapshot.processIdentifier == marker.processIdentifier else { return .stale }
    guard let bundleIdentifier = snapshot.bundleIdentifier else { return .ambiguous }
    guard bundleIdentifier == DuckDuckGoBuildCompatibilityChecker.bundleIdentifier else {
      return .stale
    }
    guard let bundleURL = snapshot.bundleURL,
      let executableURL = snapshot.executableURL,
      let launchDate = snapshot.launchDate
    else {
      return .ambiguous
    }
    guard
      canonicalFileURL(bundleURL).path
        == canonicalFileURL(URL(fileURLWithPath: marker.applicationPath)).path,
      canonicalFileURL(executableURL).path
        == canonicalFileURL(URL(fileURLWithPath: marker.executablePath)).path,
      launchDate == marker.launchDate
    else {
      return .stale
    }
    return .confirmed
  }

  private static func markerMatchesApplication(
    _ marker: DuckDuckGoManagedProcessMarker,
    applicationURL: URL,
    executableURL: URL
  ) -> Bool {
    canonicalFileURL(URL(fileURLWithPath: marker.applicationPath)).path
      == applicationURL.path
      && canonicalFileURL(URL(fileURLWithPath: marker.executablePath)).path
        == executableURL.path
  }

  private static func representsSameLaunch(
    _ current: DuckDuckGoApplicationSnapshot,
    as launched: DuckDuckGoApplicationSnapshot
  ) -> Bool {
    guard current.processIdentifier == launched.processIdentifier,
      let launchedBundleIdentifier = launched.bundleIdentifier,
      current.bundleIdentifier == launchedBundleIdentifier,
      let currentBundleURL = current.bundleURL,
      let launchedBundleURL = launched.bundleURL,
      let currentExecutableURL = current.executableURL,
      let launchedExecutableURL = launched.executableURL,
      let currentLaunchDate = current.launchDate,
      let launchedLaunchDate = launched.launchDate
    else {
      return false
    }
    return canonicalFileURL(currentBundleURL).path
      == canonicalFileURL(launchedBundleURL).path
      && canonicalFileURL(currentExecutableURL).path
        == canonicalFileURL(launchedExecutableURL).path
      && currentLaunchDate == launchedLaunchDate
  }

  private static func removeSessionIfPossible(
    _ stateStore: any DuckDuckGoManagedStateStoring,
    identifier: UUID
  ) -> Bool {
    do {
      try stateStore.removeSession(identifier: identifier)
      return true
    } catch {
      return false
    }
  }

  private static func matchesApplicationIdentity(
    _ snapshot: DuckDuckGoApplicationSnapshot,
    applicationURL: URL,
    executableURL: URL
  ) -> Bool {
    guard !snapshot.isTerminated,
      snapshot.bundleIdentifier == DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
      let bundleURL = snapshot.bundleURL,
      let runningExecutableURL = snapshot.executableURL
    else {
      return false
    }
    return canonicalFileURL(bundleURL).path == applicationURL.path
      && canonicalFileURL(runningExecutableURL).path == executableURL.path
  }

  private static func canonicalFileURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
  }
}
