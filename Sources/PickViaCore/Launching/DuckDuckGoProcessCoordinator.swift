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
  private struct LiveManagedProcess: Sendable {
    let record: DuckDuckGoManagedSessionRecord
    let snapshot: DuckDuckGoApplicationSnapshot
  }

  private let compatibilityChecker: any DuckDuckGoBuildCompatibilityChecking
  private let applications: any DuckDuckGoApplicationManaging
  private let events: any DuckDuckGoAppleEventSending
  private let stateStore: any DuckDuckGoManagedStateStoring
  private let logger = Logger(
    subsystem: "com.pickvia.app",
    category: "DuckDuckGoRouting"
  )
  private var routeIsInProgress = false
  private var routeWaiters: [CheckedContinuation<Void, Never>] = []

  public init() {
    compatibilityChecker = DuckDuckGoBuildCompatibilityChecker()
    applications = SystemDuckDuckGoApplicationManager()
    events = SystemDuckDuckGoAppleEventSender()
    stateStore = DuckDuckGoManagedStateStore()
  }

  init(
    compatibilityChecker: any DuckDuckGoBuildCompatibilityChecking =
      DuckDuckGoBuildCompatibilityChecker(),
    applications: any DuckDuckGoApplicationManaging =
      SystemDuckDuckGoApplicationManager(),
    events: any DuckDuckGoAppleEventSending =
      SystemDuckDuckGoAppleEventSender(),
    stateStore: any DuckDuckGoManagedStateStoring =
      DuckDuckGoManagedStateStore()
  ) {
    self.compatibilityChecker = compatibilityChecker
    self.applications = applications
    self.events = events
    self.stateStore = stateStore
  }

  public func open(
    url: URL,
    applicationURL: URL,
    mode: BrowserMode
  ) async throws {
    await acquireRoute()
    defer { releaseRoute() }
    try await openSerially(url: url, applicationURL: applicationURL, mode: mode)
  }

  private func openSerially(
    url: URL,
    applicationURL: URL,
    mode: BrowserMode
  ) async throws {
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

    let liveManaged = try await liveManagedProcesses(
      applicationURL: trustedApplicationURL,
      executableURL: expectedExecutableURL
    )

    switch mode {
    case .normal:
      try await openOrdinary(
        url: url,
        applicationURL: trustedApplicationURL,
        executableURL: expectedExecutableURL,
        excluding: Set(liveManaged.map(\.snapshot.processIdentifier))
      )
    case .private:
      if let existing = Self.newestLiveManaged(liveManaged) {
        try await deliverFireURL(url, to: existing.snapshot.processIdentifier)
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

  private func liveManagedProcesses(
    applicationURL: URL,
    executableURL: URL
  ) async throws -> [LiveManagedProcess] {
    let records = try stateStore.records()
    var live: [LiveManagedProcess] = []
    for record in records {
      let snapshot = await applications.snapshot(
        processIdentifier: record.marker.processIdentifier
      )
      if let snapshot,
        Self.matchesManagedIdentity(
          snapshot,
          marker: record.marker,
          applicationURL: applicationURL,
          executableURL: executableURL
        )
      {
        live.append(LiveManagedProcess(record: record, snapshot: snapshot))
      } else {
        try stateStore.removeSession(identifier: record.session.identifier)
      }
    }
    return live
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
    try await events.send(.openURL(url), processIdentifier: existing.processIdentifier)
    guard await applications.activate(processIdentifier: existing.processIdentifier) else {
      throw DuckDuckGoRoutingError.activationFailed
    }
  }

  private func launchFire(
    url: URL,
    applicationURL: URL,
    executableURL: URL
  ) async throws {
    let session = try stateStore.prepareHome(identifier: UUID())
    let launched: DuckDuckGoApplicationSnapshot
    do {
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
    } catch {
      try? stateStore.removeSession(identifier: session.identifier)
      throw error
    }

    guard
      Self.matchesApplicationIdentity(
        launched,
        applicationURL: applicationURL,
        executableURL: executableURL
      ),
      let launchDate = launched.launchDate
    else {
      throw DuckDuckGoRoutingError.processIdentityMismatch
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
      let terminated = await applications.terminate(
        processIdentifier: launched.processIdentifier
      )
      let processIsAbsent =
        await applications.snapshot(
          processIdentifier: launched.processIdentifier
        ) == nil
      if terminated || processIsAbsent {
        try? stateStore.removeSession(identifier: session.identifier)
      }
      throw error
    }

    let ready: DuckDuckGoApplicationSnapshot
    do {
      ready = try await applications.waitUntilFinishedLaunching(
        processIdentifier: launched.processIdentifier,
        timeout: .seconds(5)
      )
    } catch {
      throw DuckDuckGoRoutingError.readinessTimeout
    }
    guard
      Self.matchesManagedIdentity(
        ready,
        marker: marker,
        applicationURL: applicationURL,
        executableURL: executableURL
      )
    else {
      throw DuckDuckGoRoutingError.processIdentityMismatch
    }

    try await deliverFireURL(url, to: ready.processIdentifier)
  }

  private func deliverFireURL(_ url: URL, to processIdentifier: Int32) async throws {
    logger.debug(
      "Sending DuckDuckGo reopen event to PID \(processIdentifier, privacy: .public)"
    )
    try await events.send(.reopen, processIdentifier: processIdentifier)
    logger.debug(
      "Sending DuckDuckGo URL event to PID \(processIdentifier, privacy: .public)"
    )
    try await events.send(.openURL(url), processIdentifier: processIdentifier)
    guard await applications.activate(processIdentifier: processIdentifier) else {
      throw DuckDuckGoRoutingError.activationFailed
    }
  }

  private static func newestLiveManaged(
    _ processes: [LiveManagedProcess]
  ) -> LiveManagedProcess? {
    processes.max { $0.record.marker.launchDate < $1.record.marker.launchDate }
  }

  private static func matchesManagedIdentity(
    _ snapshot: DuckDuckGoApplicationSnapshot,
    marker: DuckDuckGoManagedProcessMarker,
    applicationURL: URL,
    executableURL: URL
  ) -> Bool {
    guard !snapshot.isTerminated,
      snapshot.processIdentifier == marker.processIdentifier,
      matchesApplicationIdentity(
        snapshot,
        applicationURL: applicationURL,
        executableURL: executableURL
      ),
      canonicalFileURL(URL(fileURLWithPath: marker.applicationPath)) == applicationURL,
      canonicalFileURL(URL(fileURLWithPath: marker.executablePath)) == executableURL,
      let launchDate = snapshot.launchDate
    else {
      return false
    }
    return abs(launchDate.timeIntervalSince(marker.launchDate)) <= 1
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
    return canonicalFileURL(bundleURL) == applicationURL
      && canonicalFileURL(runningExecutableURL) == executableURL
  }

  private static func canonicalFileURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
  }
}
