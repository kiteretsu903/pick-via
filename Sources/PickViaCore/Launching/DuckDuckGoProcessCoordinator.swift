import Foundation
import OSLog

public protocol DuckDuckGoRouting: Sendable {
  @discardableResult
  func open(
    url: URL,
    applicationURL: URL,
    mode: BrowserMode
  ) async throws -> Int32
}

enum DuckDuckGoRoutingError: Error, Equatable, Sendable {
  case unsupportedBuild
  case fireUnavailable
  case processIdentityMismatch
  case readinessTimeout
  case activationFailed
  case automationRequired
  case eventTimedOut
  case eventRejected

  // Fixed text only: never forward AppleEvent reply text, URLs, or local paths to the chooser.
  var userMessage: String {
    switch self {
    case .unsupportedBuild, .fireUnavailable:
      "This DuckDuckGo build cannot use private routing. Rescan browsers after updating PickVia, or choose another private browser."
    case .automationRequired:
      "Allow PickVia to control DuckDuckGo in System Settings → Privacy & Security → Automation, then retry."
    case .readinessTimeout:
      "DuckDuckGo did not finish starting in time. Finish any browser setup, then retry."
    case .eventTimedOut:
      "DuckDuckGo did not respond in time. Check the browser before retrying; the link may already have opened."
    case .activationFailed:
      "DuckDuckGo could not be brought forward. Check its windows before retrying; the link may already have opened."
    case .eventRejected:
      "DuckDuckGo could not complete the request. Check the browser and retry."
    case .processIdentityMismatch:
      "The selected DuckDuckGo process could not be identified. Retry or restart DuckDuckGo."
    }
  }
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

  private struct QuarantineAuthority: Sendable {
    var sessionIdentifiers: Set<UUID> = []
    var unattributedSessionIdentifiers: Set<UUID> = []
    var excludedProcessIdentifiers: Set<Int32> = []
  }

  private struct QuarantinedLaunch: Sendable {
    let session: DuckDuckGoManagedSession
    let marker: DuckDuckGoLaunchQuarantineMarker
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
  private var quarantinedLaunches: [UUID: QuarantinedLaunch] = [:]
  private var maintenanceTask: Task<Void, Never>?

  public init() {
    self.init(startsStartupCleanup: true, observesProcessExits: true)
  }

  deinit { maintenanceTask?.cancel() }

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
    startsStartupCleanup: Bool = false,
    observesProcessExits: Bool = false
  ) {
    self.compatibilityChecker = compatibilityChecker
    self.applications = applications
    self.events = events
    self.stateStore = stateStore
    self.rollbackExitTimeout = rollbackExitTimeout
    if startsStartupCleanup || observesProcessExits {
      Task { [weak self] in
        await self?.startMaintenance(
          cleanup: startsStartupCleanup, observeExits: observesProcessExits)
      }
    }
  }

  private func startMaintenance(cleanup: Bool, observeExits: Bool) {
    maintenanceTask = Task { [weak self, applications] in
      let terminations = observeExits ? await applications.terminationEvents() : nil
      if cleanup { try? await self?.waitForStartupCleanup() }
      if let terminations {
        for await _ in terminations {
          guard !Task.isCancelled else { break }
          try? await self?.waitForStartupCleanup()
        }
      }
    }
  }

  @discardableResult
  public func open(
    url: URL,
    applicationURL: URL,
    mode: BrowserMode
  ) async throws -> Int32 {
    await acquireRoute()
    defer { releaseRoute() }
    try Task.checkCancellation()
    return try await openSerially(url: url, applicationURL: applicationURL, mode: mode)
  }

  // Startup, process-exit notifications, and routes share the same recovery path.
  func waitForStartupCleanup() async throws {
    await acquireRoute()
    defer { releaseRoute() }
    do {
      let quarantine = try await reconcileQuarantinedLaunches()
      _ = try await managedProcessInventory(quarantine: quarantine)
    } catch {
      logger.error("DuckDuckGo session recovery will retry on the next route or process exit")
      throw error
    }
  }

  private func openSerially(
    url: URL,
    applicationURL: URL,
    mode: BrowserMode
  ) async throws -> Int32 {
    let trustedApplicationURL = Self.canonicalFileURL(applicationURL)
    let expectedExecutableURL = Self.canonicalFileURL(
      trustedApplicationURL.appending(path: "Contents/MacOS/DuckDuckGo")
    )

    // Ordinary links do not depend on the private-mode compatibility policy.
    if mode == .private {
      switch compatibilityChecker.compatibility(of: trustedApplicationURL) {
      case .unsupported: throw DuckDuckGoRoutingError.unsupportedBuild
      case .ordinaryOnly: throw DuckDuckGoRoutingError.fireUnavailable
      case .fire: break
      }
    }

    let quarantine: QuarantineAuthority
    var managed: ManagedProcessInventory
    do {
      quarantine = try await reconcileQuarantinedLaunches()
      managed = try await managedProcessInventory(quarantine: quarantine)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard mode == .normal else { throw error }
      // Unreadable ownership state must not block normal browsing or select an unknown instance.
      logger.error("DuckDuckGo ownership state is unavailable; opening a fresh ordinary instance")
      return try await launchOrdinary(
        url: url, applicationURL: trustedApplicationURL,
        executableURL: expectedExecutableURL)
    }
    managed.excludedProcessIdentifiers.formUnion(quarantine.excludedProcessIdentifiers)
    let mustExcludeEveryRunningProcess = !quarantine.unattributedSessionIdentifiers.isEmpty
    try Task.checkCancellation()

    switch mode {
    case .normal:
      if mustExcludeEveryRunningProcess {
        return try await launchOrdinary(
          url: url,
          applicationURL: trustedApplicationURL,
          executableURL: expectedExecutableURL
        )
      } else {
        return try await openOrdinary(
          url: url,
          applicationURL: trustedApplicationURL,
          executableURL: expectedExecutableURL,
          excluding: managed.excludedProcessIdentifiers
        )
      }
    case .private:
      let reusable = managed.confirmed.filter {
        Self.markerMatchesApplication(
          $0.record.marker,
          applicationURL: trustedApplicationURL,
          executableURL: expectedExecutableURL
        )
      }
      if let existing = Self.newestLiveManaged(reusable) {
        return try await reuseFireProcess(existing, url: url)
      } else {
        return try await launchFire(
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

  private func managedProcessInventory(
    quarantine: QuarantineAuthority
  ) async throws -> ManagedProcessInventory {
    let records = try stateStore.records()
    var inventory = ManagedProcessInventory()
    for record in records {
      if quarantine.sessionIdentifiers.contains(record.session.identifier) {
        inventory.excludedProcessIdentifiers.insert(record.marker.processIdentifier)
        continue
      }
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
        _ = Self.removeSessionIfPossible(stateStore, identifier: record.session.identifier)
      }
    }
    return inventory
  }

  private func openOrdinary(
    url: URL,
    applicationURL: URL,
    executableURL: URL,
    excluding managedProcessIdentifiers: Set<Int32>
  ) async throws -> Int32 {
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
      return try await launchOrdinary(
        url: url,
        applicationURL: applicationURL,
        executableURL: executableURL
      )
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
    return try Self.positiveProcessIdentifier(existing.processIdentifier)
  }

  private func launchOrdinary(
    url: URL,
    applicationURL: URL,
    executableURL: URL
  ) async throws -> Int32 {
    try Task.checkCancellation()
    let launched = try await applications.launch(
      DuckDuckGoApplicationLaunchRequest(
        applicationURL: applicationURL,
        urls: [url],
        createsNewApplicationInstance: true,
        arguments: [],
        environment: [:],
        activates: true
      )
    )
    guard
      Self.matchesApplicationIdentity(
        launched,
        applicationURL: applicationURL,
        executableURL: executableURL
      )
    else {
      throw DuckDuckGoRoutingError.processIdentityMismatch
    }
    return try Self.positiveProcessIdentifier(launched.processIdentifier)
  }

  private func launchFire(
    url: URL,
    applicationURL: URL,
    executableURL: URL
  ) async throws -> Int32 {
    try Task.checkCancellation()
    let session = try stateStore.prepareHome(identifier: UUID())
    let pendingQuarantine = DuckDuckGoLaunchQuarantineMarker(
      identifier: session.identifier,
      processIdentifier: nil,
      launchDate: nil,
      applicationPath: applicationURL.path,
      executablePath: executableURL.path
    )
    quarantinedLaunches[session.identifier] = QuarantinedLaunch(
      session: session,
      marker: pendingQuarantine
    )
    do {
      try stateStore.saveQuarantine(pendingQuarantine, for: session)
    } catch {
      if Self.removeSessionIfPossible(stateStore, identifier: session.identifier) {
        quarantinedLaunches.removeValue(forKey: session.identifier)
      }
      throw error
    }

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
      quarantinedLaunches[session.identifier] = QuarantinedLaunch(
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
      if Self.removeSessionIfPossible(stateStore, identifier: session.identifier) {
        quarantinedLaunches.removeValue(forKey: session.identifier)
      }
      throw error
    }

    let launchProcessIdentifier: Int32
    do {
      launchProcessIdentifier = try Self.positiveProcessIdentifier(
        launched.processIdentifier
      )
    } catch {
      await rollbackFreshLaunch(launched, session: session)
      throw error
    }

    do {
      guard let quarantine = quarantinedLaunches[session.identifier] else {
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
    quarantinedLaunches.removeValue(forKey: session.identifier)

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
    return launchProcessIdentifier
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
  ) async throws -> Int32 {
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
    return try Self.positiveProcessIdentifier(snapshot.processIdentifier)
  }

  private func rollbackFreshLaunch(
    _ launched: DuckDuckGoApplicationSnapshot,
    session: DuckDuckGoManagedSession
  ) async {
    // If a write reported failure after committing, restore pending state before
    // requesting termination so a restart cannot reuse a process that is being rolled back.
    if let launch = quarantinedLaunches[session.identifier] {
      try? stateStore.saveQuarantine(launch.marker, for: session)
    }
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
      quarantinedLaunches.removeValue(forKey: session.identifier)
    }
  }

  private func reconcileQuarantinedLaunches() async throws -> QuarantineAuthority {
    var opaqueSessionIdentifiers: Set<UUID> = []
    for entry in try stateStore.quarantineEntries() {
      switch entry {
      case .valid(let record):
        // Preserve the returned PID if its post-launch write failed and disk still
        // contains our PID-less pending record. Otherwise current disk authority wins.
        let pending = quarantinedLaunches[record.session.identifier]?.marker
        let hasMorePrecisePendingIdentity =
          record.marker.processIdentifier == nil
          && pending?.processIdentifier != nil
          && pending?.applicationPath == record.marker.applicationPath
          && pending?.executablePath == record.marker.executablePath
        if !hasMorePrecisePendingIdentity {
          quarantinedLaunches[record.session.identifier] = QuarantinedLaunch(
            session: record.session, marker: record.marker)
        }
      case .invalid(let session):
        opaqueSessionIdentifiers.insert(session.identifier)
        quarantinedLaunches.removeValue(forKey: session.identifier)
      }
    }

    let processRecords = try stateStore.records()
    let processRecordsBySession = Dictionary(
      uniqueKeysWithValues: processRecords.map { ($0.session.identifier, $0) }
    )
    var reapedSessionIdentifiers: [UUID] = []
    for (sessionIdentifier, launch) in quarantinedLaunches {
      guard let processIdentifier = launch.marker.processIdentifier else { continue }
      let snapshot = await applications.snapshot(processIdentifier: processIdentifier)
      guard Self.quarantineIsStale(snapshot, marker: launch.marker) else {
        continue
      }
      try Task.checkCancellation()
      do {
        if let processRecord = processRecordsBySession[sessionIdentifier] {
          let processSnapshot = await applications.snapshot(
            processIdentifier: processRecord.marker.processIdentifier
          )
          try Task.checkCancellation()
          switch Self.evaluateManagedIdentity(
            processSnapshot,
            marker: processRecord.marker
          ) {
          case .confirmed:
            try stateStore.removeQuarantine(for: launch.session)
          case .ambiguous:
            continue
          case .stale:
            try stateStore.removeSession(identifier: launch.session.identifier)
          }
        } else {
          try stateStore.removeSession(identifier: launch.session.identifier)
        }
      } catch {
        logger.error("DuckDuckGo stale session cleanup will retry later")
        continue
      }
      reapedSessionIdentifiers.append(sessionIdentifier)
    }
    for sessionIdentifier in reapedSessionIdentifiers {
      quarantinedLaunches.removeValue(forKey: sessionIdentifier)
    }
    var authority = QuarantineAuthority(
      sessionIdentifiers: opaqueSessionIdentifiers,
      unattributedSessionIdentifiers: opaqueSessionIdentifiers
    )
    for launch in quarantinedLaunches.values {
      authority.sessionIdentifiers.insert(launch.session.identifier)
      if let processIdentifier = launch.marker.processIdentifier {
        authority.excludedProcessIdentifiers.insert(processIdentifier)
      } else {
        authority.unattributedSessionIdentifiers.insert(launch.session.identifier)
      }
    }
    return authority
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

  private static func positiveProcessIdentifier(
    _ processIdentifier: Int32
  ) throws -> Int32 {
    guard processIdentifier > 0 else {
      throw DuckDuckGoRoutingError.processIdentityMismatch
    }
    return processIdentifier
  }

  private static func canonicalFileURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
  }
}
