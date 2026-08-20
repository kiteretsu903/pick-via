import Foundation
import Testing

@testable import PickViaCore

@Suite("DuckDuckGo process coordinator")
struct DuckDuckGoProcessCoordinatorTests {
  @Test func firstFireRouteLaunchesWithoutURLThenReopensThenSendsURL() async throws {
    let fixture = try CoordinatorFixture(compatibility: .fire)
    defer { fixture.removeRoot() }
    let url = URL(string: "https://example.com/fire")!

    try await fixture.coordinator.open(
      url: url,
      applicationURL: fixture.applicationURL,
      mode: .private
    )

    let launches = await fixture.applications.launches
    #expect(launches.count == 1)
    #expect(launches[0].applicationURL == fixture.applicationURL)
    #expect(launches[0].urls.isEmpty)
    #expect(launches[0].createsNewApplicationInstance)
    #expect(launches[0].arguments == ["-ApplePersistenceIgnoreState", "YES"])
    #expect(
      launches[0].environment["CFFIXED_USER_HOME"]?
        .hasPrefix(fixture.root.path) == true
    )
    #expect(!launches[0].activates)
    #expect(await fixture.applications.waitTimeouts == [.seconds(5)])
    #expect(
      await fixture.events.invocations == [
        .init(event: .reopen, processIdentifier: 7001),
        .init(event: .openURL(url), processIdentifier: 7001),
      ]
    )
    #expect(await fixture.applications.activatedPIDs == [7001])

    let record = try #require(fixture.realStore.records().only)
    #expect(record.marker.processIdentifier == 7001)
    #expect(record.marker.launchDate == fixture.nextLaunch.launchDate)
    #expect(record.marker.applicationPath == fixture.applicationURL.path)
    #expect(record.marker.executablePath == fixture.executableURL.path)
  }

  @Test func validManagedProcessIsReusedWithReopenBeforeURL() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      existingManagedPIDs: [7001]
    )
    defer { fixture.removeRoot() }
    let url = URL(string: "https://example.com/reopen")!

    try await fixture.coordinator.open(
      url: url,
      applicationURL: fixture.applicationURL,
      mode: .private
    )

    #expect(await fixture.applications.launches.isEmpty)
    #expect(await fixture.applications.waitTimeouts.isEmpty)
    #expect(
      await fixture.events.invocations == [
        .init(event: .reopen, processIdentifier: 7001),
        .init(event: .openURL(url), processIdentifier: 7001),
      ]
    )
    #expect(try fixture.realStore.records().count == 1)
  }

  @Test func unfinishedManagedProcessWaitsBeforeReuse() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      existingManagedPIDs: [7001]
    )
    defer { fixture.removeRoot() }
    await fixture.applications.mutateSnapshot(processIdentifier: 7001) { value in
      DuckDuckGoApplicationSnapshot(
        processIdentifier: value.processIdentifier,
        bundleIdentifier: value.bundleIdentifier,
        bundleURL: value.bundleURL,
        executableURL: value.executableURL,
        launchDate: value.launchDate,
        isFinishedLaunching: false,
        isTerminated: value.isTerminated
      )
    }

    try await fixture.coordinator.open(
      url: URL(string: "https://example.com/wait-before-reuse")!,
      applicationURL: fixture.applicationURL,
      mode: .private
    )

    #expect(await fixture.applications.waitTimeouts == [.seconds(5)])
    #expect(await fixture.events.invocations.map(\.processIdentifier) == [7001, 7001])
  }

  @Test func concurrentFireRoutesSerializeAroundTheFirstLaunch() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      suspendsLaunch: true
    )
    defer { fixture.removeRoot() }
    let first = Task {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/concurrent-first")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    await fixture.applications.waitUntilLaunchCount(1)

    let second = Task {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/concurrent-second")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    for _ in 0..<20 { await Task.yield() }

    #expect(await fixture.applications.launches.count == 1)
    await fixture.applications.resumeSuspendedLaunches()
    try await first.value
    try await second.value
    #expect(await fixture.applications.launches.count == 1)
  }

  @Test func cancelledQueuedRouteDoesNotLaunchOrDeliverEvents() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      suspendsLaunch: true
    )
    defer { fixture.removeRoot() }
    let firstURL = URL(string: "https://example.com/cancellation-first")!
    let first = Task {
      try await fixture.coordinator.open(
        url: firstURL,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    await fixture.applications.waitUntilLaunchCount(1)
    let cancelled = Task {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/cancelled")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    for _ in 0..<20 { await Task.yield() }
    cancelled.cancel()

    await fixture.applications.resumeSuspendedLaunches()
    try await first.value
    await #expect(throws: CancellationError.self) {
      try await cancelled.value
    }
    #expect(await fixture.applications.launches.count == 1)
    #expect(
      await fixture.events.invocations.map(\.event) == [
        .reopen, .openURL(firstURL),
      ]
    )
  }

  @Test func newestManagedProcessIsReused() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      existingManagedPIDs: [7001, 7002]
    )
    defer { fixture.removeRoot() }

    try await fixture.coordinator.open(
      url: URL(string: "https://example.com/newest-managed")!,
      applicationURL: fixture.applicationURL,
      mode: .private
    )

    #expect(await fixture.events.invocations.map(\.processIdentifier) == [7002, 7002])
  }

  @Test func ordinaryRouteExcludesEveryManagedPIDAndUsesNewestUnmanaged() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      existingManagedPIDs: [7001, 7002],
      unmanagedPIDs: [8001, 8002]
    )
    defer { fixture.removeRoot() }
    let url = URL(string: "https://example.com/ordinary")!

    try await fixture.coordinator.open(
      url: url,
      applicationURL: fixture.applicationURL,
      mode: .normal
    )

    #expect(await fixture.applications.launches.isEmpty)
    #expect(
      await fixture.events.invocations == [
        .init(event: .openURL(url), processIdentifier: 8002)
      ]
    )
    #expect(await fixture.applications.activatedPIDs == [8002])
  }

  @Test func liveManagedIdentityAtAnotherCanonicalAppPathIsPreserved() async throws {
    let fixture = try CoordinatorFixture(compatibility: .fire)
    defer { fixture.removeRoot() }
    let otherApplicationURL = URL(
      fileURLWithPath: "/Volumes/Other/DuckDuckGo.app",
      isDirectory: true
    )
    let otherExecutableURL = otherApplicationURL.appending(
      path: "Contents/MacOS/DuckDuckGo"
    )
    let launchDate = Date(timeIntervalSince1970: 4_321)
    let session = try fixture.realStore.prepareHome()
    try fixture.realStore.save(
      DuckDuckGoManagedProcessMarker(
        identifier: session.identifier,
        processIdentifier: 7101,
        launchDate: launchDate,
        applicationPath: otherApplicationURL.path,
        executablePath: otherExecutableURL.path
      ),
      for: session
    )
    await fixture.applications.setSnapshot(
      DuckDuckGoProcessCoordinatorTests.makeSnapshot(
        processIdentifier: 7101,
        applicationURL: otherApplicationURL,
        executableURL: otherExecutableURL,
        launchDate: launchDate
      )
    )

    try await fixture.coordinator.open(
      url: URL(string: "https://example.com/current-install")!,
      applicationURL: fixture.applicationURL,
      mode: .normal
    )

    #expect(try fixture.realStore.records().map(\.marker.processIdentifier) == [7101])
    #expect(await fixture.applications.launches.count == 1)
    #expect(await fixture.events.invocations.isEmpty)
  }

  @Test func privateRoutePreservesButDoesNotReuseAnotherCanonicalAppPath() async throws {
    let fixture = try CoordinatorFixture(compatibility: .fire)
    defer { fixture.removeRoot() }
    let otherApplicationURL = URL(
      fileURLWithPath: "/Volumes/Other/DuckDuckGo.app",
      isDirectory: true
    )
    let otherExecutableURL = otherApplicationURL.appending(
      path: "Contents/MacOS/DuckDuckGo"
    )
    let launchDate = Date(timeIntervalSince1970: 4_321)
    let session = try fixture.realStore.prepareHome()
    try fixture.realStore.save(
      DuckDuckGoManagedProcessMarker(
        identifier: session.identifier,
        processIdentifier: 7101,
        launchDate: launchDate,
        applicationPath: otherApplicationURL.path,
        executablePath: otherExecutableURL.path
      ),
      for: session
    )
    await fixture.applications.setSnapshot(
      DuckDuckGoProcessCoordinatorTests.makeSnapshot(
        processIdentifier: 7101,
        applicationURL: otherApplicationURL,
        executableURL: otherExecutableURL,
        launchDate: launchDate
      )
    )

    try await fixture.coordinator.open(
      url: URL(string: "https://example.com/current-fire")!,
      applicationURL: fixture.applicationURL,
      mode: .private
    )

    #expect(await fixture.applications.launches.count == 1)
    #expect(
      !(await fixture.events.invocations).contains {
        $0.processIdentifier == 7101
      }
    )
    #expect(
      try fixture.realStore.records().map(\.marker.processIdentifier).sorted()
        == [7001, 7101]
    )
  }

  @Test func ordinaryStartsRealHomeInstanceWhenOnlyManagedProcessExists() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      existingManagedPIDs: [7001]
    )
    defer { fixture.removeRoot() }
    let url = URL(string: "https://example.com/ordinary-new")!

    try await fixture.coordinator.open(
      url: url,
      applicationURL: fixture.applicationURL,
      mode: .normal
    )

    let launch = try #require(await fixture.applications.launches.first)
    #expect(launch.applicationURL == fixture.applicationURL)
    #expect(launch.urls == [url])
    #expect(launch.environment.isEmpty)
    #expect(launch.arguments.isEmpty)
    #expect(launch.createsNewApplicationInstance)
    #expect(launch.activates)
    #expect(await fixture.events.invocations.isEmpty)
  }

  @Test func ordinaryOnlyBuildRejectsFireWithoutFallback() async throws {
    let fixture = try CoordinatorFixture(compatibility: .ordinaryOnly)
    defer { fixture.removeRoot() }

    await #expect(throws: DuckDuckGoRoutingError.fireUnavailable) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/no-fire")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.applications.launches.isEmpty)
    #expect(await fixture.events.invocations.isEmpty)
  }

  @Test(arguments: [BrowserMode.normal, .private])
  func unsupportedBuildRejectsBothModes(_ mode: BrowserMode) async throws {
    let fixture = try CoordinatorFixture(compatibility: .unsupported)
    defer { fixture.removeRoot() }

    await #expect(throws: DuckDuckGoRoutingError.unsupportedBuild) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/unsupported")!,
        applicationURL: fixture.applicationURL,
        mode: mode
      )
    }
    #expect(await fixture.applications.launches.isEmpty)
    #expect(await fixture.events.invocations.isEmpty)
  }

  @Test func compatibilityIsRecheckedForEveryOpen() async throws {
    let checker = SequenceDuckDuckGoCompatibility(values: [.fire, .unsupported])
    let fixture = try CoordinatorFixture(
      compatibilityChecker: checker,
      existingManagedPIDs: [7001]
    )
    defer { fixture.removeRoot() }

    try await fixture.coordinator.open(
      url: URL(string: "https://example.com/first")!,
      applicationURL: fixture.applicationURL,
      mode: .private
    )
    await #expect(throws: DuckDuckGoRoutingError.unsupportedBuild) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/second")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(checker.receivedURLs == [fixture.applicationURL, fixture.applicationURL])
  }

  @Test func reusedPIDWithDifferentLaunchDateIsNeverTargetedAndIsCleaned() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      existingManagedPIDs: [7001],
      managedSnapshotLaunchDateOffset: 60
    )
    defer { fixture.removeRoot() }

    try await fixture.coordinator.open(
      url: URL(string: "https://example.com/fresh")!,
      applicationURL: fixture.applicationURL,
      mode: .private
    )

    #expect(
      !(await fixture.events.invocations).contains {
        $0.processIdentifier == 7001
      }
    )
    #expect(await fixture.applications.launches.count == 1)
    #expect(try fixture.realStore.records().map(\.marker.processIdentifier) == [9001])
  }

  @Test func terminatedManagedProcessIsCleanedBeforeReuse() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      existingManagedPIDs: [7001],
      managedProcessIsTerminated: true
    )
    defer { fixture.removeRoot() }

    try await fixture.coordinator.open(
      url: URL(string: "https://example.com/replacement")!,
      applicationURL: fixture.applicationURL,
      mode: .private
    )

    #expect(
      !(await fixture.events.invocations).contains {
        $0.processIdentifier == 7001
      }
    )
    #expect(await fixture.applications.launches.count == 1)
    #expect(try fixture.realStore.records().map(\.marker.processIdentifier) == [9001])
  }

  @Test func missingManagedLaunchDateIsPreservedAndNotTargetedAsOrdinary() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      existingManagedPIDs: [7001],
      unmanagedPIDs: [8001]
    )
    defer { fixture.removeRoot() }
    await fixture.applications.mutateSnapshot(processIdentifier: 7001) { value in
      DuckDuckGoApplicationSnapshot(
        processIdentifier: value.processIdentifier,
        bundleIdentifier: value.bundleIdentifier,
        bundleURL: value.bundleURL,
        executableURL: value.executableURL,
        launchDate: nil,
        isFinishedLaunching: value.isFinishedLaunching,
        isTerminated: value.isTerminated
      )
    }

    try await fixture.coordinator.open(
      url: URL(string: "https://example.com/ambiguous-date")!,
      applicationURL: fixture.applicationURL,
      mode: .normal
    )

    #expect(try fixture.realStore.records().map(\.marker.processIdentifier) == [7001])
    #expect(await fixture.events.invocations.map(\.processIdentifier) == [8001])
  }

  @Test func missingManagedBundlePathIsPreservedAndNotTargetedAsOrdinary() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      existingManagedPIDs: [7001],
      unmanagedPIDs: [8001]
    )
    defer { fixture.removeRoot() }
    await fixture.applications.mutateSnapshot(processIdentifier: 7001) { value in
      DuckDuckGoApplicationSnapshot(
        processIdentifier: value.processIdentifier,
        bundleIdentifier: value.bundleIdentifier,
        bundleURL: nil,
        executableURL: value.executableURL,
        launchDate: value.launchDate,
        isFinishedLaunching: value.isFinishedLaunching,
        isTerminated: value.isTerminated
      )
    }

    try await fixture.coordinator.open(
      url: URL(string: "https://example.com/ambiguous-path")!,
      applicationURL: fixture.applicationURL,
      mode: .normal
    )

    #expect(try fixture.realStore.records().map(\.marker.processIdentifier) == [7001])
    #expect(await fixture.events.invocations.map(\.processIdentifier) == [8001])
  }

  @Test func mismatchedBundleAndExecutableManagedRecordsAreBothExcludedFromNormal()
    async throws
  {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      existingManagedPIDs: [7001, 7002],
      unmanagedPIDs: []
    )
    defer { fixture.removeRoot() }
    await fixture.applications.mutateSnapshot(processIdentifier: 7001) {
      snapshot in
      Self.snapshot(copying: snapshot, bundleIdentifier: "wrong.bundle")
    }
    await fixture.applications.mutateSnapshot(processIdentifier: 7002) {
      snapshot in
      Self.snapshot(
        copying: snapshot,
        executableURL: URL(fileURLWithPath: "/tmp/not-duckduckgo")
      )
    }

    try await fixture.coordinator.open(
      url: URL(string: "https://example.com/normal-mismatch")!,
      applicationURL: fixture.applicationURL,
      mode: .normal
    )

    #expect(await fixture.applications.launches.count == 1)
    #expect(try fixture.realStore.records().count == 0)
  }

  @Test func consentRequiredAppleEventErrorPropagatesWithoutFallback() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      eventErrorCode: -1744
    )
    defer { fixture.removeRoot() }

    do {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/no-consent")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
      Issue.record("Expected the Apple-event error")
    } catch let error as NSError {
      #expect(error.domain == NSOSStatusErrorDomain)
      #expect(error.code == -1744)
    }
    #expect(await fixture.applications.launches.count == 1)
    #expect(await fixture.events.invocations.map(\.event) == [.reopen])
    #expect(await fixture.applications.terminatedPIDs.isEmpty)
    #expect(try fixture.realStore.records().count == 1)
  }

  @Test func activationFailureIsReportedWithoutTerminatingManagedProcess() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      activationSucceeds: false
    )
    defer { fixture.removeRoot() }
    let url = URL(string: "https://example.com/not-activated")!

    await #expect(throws: DuckDuckGoRoutingError.activationFailed) {
      try await fixture.coordinator.open(
        url: url,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.events.invocations.map(\.event) == [.reopen, .openURL(url)])
    #expect(await fixture.applications.terminatedPIDs.isEmpty)
    #expect(try fixture.realStore.records().count == 1)
  }

  @Test func ordinaryActivationFailureIsReported() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .ordinaryOnly,
      unmanagedPIDs: [8001],
      activationSucceeds: false
    )
    defer { fixture.removeRoot() }

    await #expect(throws: DuckDuckGoRoutingError.activationFailed) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/ordinary-activation")!,
        applicationURL: fixture.applicationURL,
        mode: .normal
      )
    }
    #expect(await fixture.events.invocations.count == 1)
    #expect(await fixture.applications.launches.isEmpty)
  }

  @Test func launchFailureRemovesFreshSession() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      launchError: TestFailure.launch
    )
    defer { fixture.removeRoot() }

    await #expect(throws: TestFailure.launch) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/launch-failure")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.applications.terminatedPIDs.isEmpty)
    #expect(fixture.sessionDirectoryNames().isEmpty)
  }

  @Test func markerFailureTerminatesExactPIDThenRemovesSession() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      storeFailure: .save,
      terminationSucceeds: true
    )
    defer { fixture.removeRoot() }

    await #expect(throws: TestFailure.save) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/save-failure")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.applications.terminatedPIDs == [7001])
    #expect(fixture.sessionDirectoryNames().isEmpty)
    #expect(await fixture.events.invocations.isEmpty)
  }

  @Test func markerFailurePreservesSessionUntilSuccessfulTerminationActuallyExits()
    async throws
  {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      storeFailure: .save,
      terminationSucceeds: true,
      keepsSnapshotAfterSuccessfulTermination: true
    )
    defer { fixture.removeRoot() }

    await #expect(throws: TestFailure.save) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/still-live")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.applications.terminatedPIDs == [7001])
    #expect(fixture.sessionDirectoryNames().count == 1)
  }

  @Test func markerFailurePreservesSessionWhenTerminationFailsAndPIDStillExists()
    async throws
  {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      storeFailure: .save,
      terminationSucceeds: false,
      removesSnapshotWhenTerminationFails: false
    )
    defer { fixture.removeRoot() }

    await #expect(throws: TestFailure.save) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/keep-failed-save")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.applications.terminatedPIDs == [7001])
    #expect(fixture.sessionDirectoryNames().count == 1)
  }

  @Test func markerFailureRemovesSessionWhenPIDDisappearsDespiteFailedTermination()
    async throws
  {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      storeFailure: .save,
      terminationSucceeds: false,
      removesSnapshotWhenTerminationFails: true
    )
    defer { fixture.removeRoot() }

    await #expect(throws: TestFailure.save) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/disappeared")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.applications.terminatedPIDs == [7001])
    #expect(fixture.sessionDirectoryNames().isEmpty)
  }

  @Test func readinessFailurePreservesMarkerAndDoesNotTerminateProcess() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      waitError: TestFailure.wait
    )
    defer { fixture.removeRoot() }

    await #expect(throws: DuckDuckGoRoutingError.readinessTimeout) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/wait-failure")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.applications.terminatedPIDs.isEmpty)
    #expect(try fixture.realStore.records().count == 1)
    #expect(await fixture.events.invocations.isEmpty)
  }

  @Test func launchedProcessIdentityMismatchFailsClosedBeforeMarkerPersistence() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      launchedBundleIdentifier: "not.duckduckgo"
    )
    defer { fixture.removeRoot() }

    await #expect(throws: DuckDuckGoRoutingError.processIdentityMismatch) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/bad-process")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.events.invocations.isEmpty)
    #expect(await fixture.applications.terminatedPIDs == [7001])
    #expect(try fixture.realStore.records().isEmpty)
    #expect(fixture.sessionDirectoryNames().isEmpty)
  }

  @Test func identityMismatchPreservesSessionUntilRollbackExitIsConfirmed() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      terminationSucceeds: true,
      keepsSnapshotAfterSuccessfulTermination: true,
      launchedBundleIdentifier: "not.duckduckgo"
    )
    defer { fixture.removeRoot() }

    await #expect(throws: DuckDuckGoRoutingError.processIdentityMismatch) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/bad-process-still-live")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.applications.terminatedPIDs == [7001])
    #expect(fixture.sessionDirectoryNames().count == 1)
  }

  @Test func identityMismatchDoesNotTerminateWhenReturnedIdentityIsAmbiguous() async throws {
    let fixture = try CoordinatorFixture(
      compatibility: .fire,
      launchedBundleIdentifier: nil
    )
    defer { fixture.removeRoot() }

    await #expect(throws: DuckDuckGoRoutingError.processIdentityMismatch) {
      try await fixture.coordinator.open(
        url: URL(string: "https://example.com/ambiguous-returned-process")!,
        applicationURL: fixture.applicationURL,
        mode: .private
      )
    }
    #expect(await fixture.applications.terminatedPIDs.isEmpty)
    #expect(fixture.sessionDirectoryNames().count == 1)
  }

  @Test func resolvedApplicationURLIsUsedForCompatibilityAndLaunch() async throws {
    let parent = FileManager.default.temporaryDirectory.appending(
      path: "PickVia-DuckDuckGo-Link-\(UUID())",
      directoryHint: .isDirectory
    )
    let realApplicationURL = parent.appending(path: "DuckDuckGo.app")
    let linkedApplicationURL = parent.appending(path: "DuckDuckGo Link.app")
    try FileManager.default.createDirectory(
      at: realApplicationURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
      at: linkedApplicationURL,
      withDestinationURL: realApplicationURL
    )
    defer { try? FileManager.default.removeItem(at: parent) }
    let checker = SequenceDuckDuckGoCompatibility(values: [.ordinaryOnly])
    let executableURL = realApplicationURL.appending(
      path: "Contents/MacOS/DuckDuckGo"
    )
    let applications = RecordingDuckDuckGoApplicationManager(
      snapshots: [:],
      nextLaunch: Self.makeSnapshot(
        processIdentifier: 7001,
        applicationURL: realApplicationURL,
        executableURL: executableURL,
        launchDate: Date(timeIntervalSince1970: 1_234)
      )
    )
    let root = parent.appending(path: "State")
    let coordinator = DuckDuckGoProcessCoordinator(
      compatibilityChecker: checker,
      applications: applications,
      events: RecordingDuckDuckGoAppleEventSender(),
      stateStore: DuckDuckGoManagedStateStore(rootDirectory: root)
    )

    try await coordinator.open(
      url: URL(string: "https://example.com/resolved")!,
      applicationURL: linkedApplicationURL,
      mode: .normal
    )

    let resolvedApplicationURL = linkedApplicationURL.standardizedFileURL
      .resolvingSymlinksInPath().standardizedFileURL
    #expect(checker.receivedURLs == [resolvedApplicationURL])
    #expect(
      await applications.launches.only?.applicationURL == resolvedApplicationURL
    )
  }

  private static func snapshot(
    copying value: DuckDuckGoApplicationSnapshot,
    bundleIdentifier: String? = nil,
    executableURL: URL? = nil
  ) -> DuckDuckGoApplicationSnapshot {
    DuckDuckGoApplicationSnapshot(
      processIdentifier: value.processIdentifier,
      bundleIdentifier: bundleIdentifier ?? value.bundleIdentifier,
      bundleURL: value.bundleURL,
      executableURL: executableURL ?? value.executableURL,
      launchDate: value.launchDate,
      isFinishedLaunching: value.isFinishedLaunching,
      isTerminated: value.isTerminated
    )
  }

  fileprivate static func makeSnapshot(
    processIdentifier: Int32,
    applicationURL: URL,
    executableURL: URL,
    launchDate: Date,
    isTerminated: Bool = false,
    bundleIdentifier: String? = DuckDuckGoBuildCompatibilityChecker.bundleIdentifier
  ) -> DuckDuckGoApplicationSnapshot {
    DuckDuckGoApplicationSnapshot(
      processIdentifier: processIdentifier,
      bundleIdentifier: bundleIdentifier,
      bundleURL: applicationURL,
      executableURL: executableURL,
      launchDate: launchDate,
      isFinishedLaunching: true,
      isTerminated: isTerminated
    )
  }
}

private actor RecordingDuckDuckGoApplicationManager: DuckDuckGoApplicationManaging {
  var snapshots: [Int32: DuckDuckGoApplicationSnapshot]
  var nextLaunch: DuckDuckGoApplicationSnapshot
  private(set) var launches: [DuckDuckGoApplicationLaunchRequest] = []
  private(set) var activatedPIDs: [Int32] = []
  private(set) var terminatedPIDs: [Int32] = []
  private(set) var waitTimeouts: [Duration] = []
  let activationSucceeds: Bool
  let terminationSucceeds: Bool
  let removesSnapshotOnTermination: Bool
  let launchError: TestFailure?
  let waitError: TestFailure?
  let suspendsLaunch: Bool
  private var suspendedLaunches: [CheckedContinuation<Void, Never>] = []

  init(
    snapshots: [Int32: DuckDuckGoApplicationSnapshot],
    nextLaunch: DuckDuckGoApplicationSnapshot,
    activationSucceeds: Bool = true,
    terminationSucceeds: Bool = true,
    removesSnapshotOnTermination: Bool = true,
    launchError: TestFailure? = nil,
    waitError: TestFailure? = nil,
    suspendsLaunch: Bool = false
  ) {
    self.snapshots = snapshots
    self.nextLaunch = nextLaunch
    self.activationSucceeds = activationSucceeds
    self.terminationSucceeds = terminationSucceeds
    self.removesSnapshotOnTermination = removesSnapshotOnTermination
    self.launchError = launchError
    self.waitError = waitError
    self.suspendsLaunch = suspendsLaunch
  }

  func runningApplications(bundleIdentifier: String) async
    -> [DuckDuckGoApplicationSnapshot]
  {
    snapshots.values.filter { $0.bundleIdentifier == bundleIdentifier }
  }

  func launch(_ request: DuckDuckGoApplicationLaunchRequest) async throws
    -> DuckDuckGoApplicationSnapshot
  {
    launches.append(request)
    if let launchError { throw launchError }
    if suspendsLaunch && launches.count == 1 {
      await withCheckedContinuation { continuation in
        suspendedLaunches.append(continuation)
      }
    }
    snapshots[nextLaunch.processIdentifier] = nextLaunch
    return nextLaunch
  }

  func waitUntilLaunchCount(_ expectedCount: Int) async {
    while launches.count < expectedCount {
      await Task.yield()
    }
  }

  func resumeSuspendedLaunches() {
    let values = suspendedLaunches
    suspendedLaunches.removeAll()
    for value in values { value.resume() }
  }

  func snapshot(processIdentifier: Int32) async -> DuckDuckGoApplicationSnapshot? {
    snapshots[processIdentifier]
  }

  func waitUntilFinishedLaunching(
    processIdentifier: Int32,
    timeout: Duration
  ) async throws -> DuckDuckGoApplicationSnapshot {
    waitTimeouts.append(timeout)
    if let waitError { throw waitError }
    guard let value = snapshots[processIdentifier], !value.isTerminated else {
      throw DuckDuckGoApplicationManagerError.launchTimedOut(
        processIdentifier: processIdentifier)
    }
    return value
  }

  func activate(processIdentifier: Int32) async -> Bool {
    activatedPIDs.append(processIdentifier)
    return activationSucceeds
      && snapshots[processIdentifier]?.isTerminated == false
  }

  func terminate(processIdentifier: Int32) async -> Bool {
    terminatedPIDs.append(processIdentifier)
    if removesSnapshotOnTermination {
      snapshots.removeValue(forKey: processIdentifier)
    }
    return terminationSucceeds
  }

  func mutateSnapshot(
    processIdentifier: Int32,
    transform: @Sendable (DuckDuckGoApplicationSnapshot) -> DuckDuckGoApplicationSnapshot
  ) {
    guard let value = snapshots[processIdentifier] else { return }
    snapshots[processIdentifier] = transform(value)
  }

  func setSnapshot(_ snapshot: DuckDuckGoApplicationSnapshot) {
    snapshots[snapshot.processIdentifier] = snapshot
  }
}

private actor RecordingDuckDuckGoAppleEventSender: DuckDuckGoAppleEventSending {
  struct Invocation: Equatable, Sendable {
    let event: DuckDuckGoAppleEvent
    let processIdentifier: Int32
  }

  private(set) var invocations: [Invocation] = []
  let errorCode: Int?

  init(errorCode: Int? = nil) {
    self.errorCode = errorCode
  }

  func send(
    _ event: DuckDuckGoAppleEvent,
    processIdentifier: Int32
  ) async throws {
    invocations.append(.init(event: event, processIdentifier: processIdentifier))
    if let errorCode {
      throw NSError(domain: NSOSStatusErrorDomain, code: errorCode)
    }
  }
}

private struct StubDuckDuckGoCompatibility: DuckDuckGoBuildCompatibilityChecking {
  let value: DuckDuckGoBuildCompatibility

  func compatibility(of applicationURL: URL) -> DuckDuckGoBuildCompatibility {
    value
  }
}

private final class SequenceDuckDuckGoCompatibility:
  DuckDuckGoBuildCompatibilityChecking, @unchecked Sendable
{
  private let lock = NSLock()
  private var values: [DuckDuckGoBuildCompatibility]
  private var urls: [URL] = []

  init(values: [DuckDuckGoBuildCompatibility]) {
    self.values = values
  }

  var receivedURLs: [URL] {
    lock.withLock { urls }
  }

  func compatibility(of applicationURL: URL) -> DuckDuckGoBuildCompatibility {
    lock.withLock {
      urls.append(applicationURL)
      return values.removeFirst()
    }
  }
}

private final class FailingDuckDuckGoManagedStateStore:
  DuckDuckGoManagedStateStoring, @unchecked Sendable
{
  enum Failure {
    case save
  }

  let underlying: DuckDuckGoManagedStateStore
  let failure: Failure?

  init(underlying: DuckDuckGoManagedStateStore, failure: Failure?) {
    self.underlying = underlying
    self.failure = failure
  }

  func prepareHome(identifier: UUID) throws -> DuckDuckGoManagedSession {
    try underlying.prepareHome(identifier: identifier)
  }

  func save(
    _ marker: DuckDuckGoManagedProcessMarker,
    for session: DuckDuckGoManagedSession
  ) throws {
    if failure == .save { throw TestFailure.save }
    try underlying.save(marker, for: session)
  }

  func records() throws -> [DuckDuckGoManagedSessionRecord] {
    try underlying.records()
  }

  func removeSession(identifier: UUID) throws {
    try underlying.removeSession(identifier: identifier)
  }
}

private final class CoordinatorFixture: @unchecked Sendable {
  let root: URL
  let applicationURL = URL(
    fileURLWithPath: "/Applications/DuckDuckGo.app",
    isDirectory: true
  )
  let executableURL: URL
  let nextLaunch: DuckDuckGoApplicationSnapshot
  let realStore: DuckDuckGoManagedStateStore
  let applications: RecordingDuckDuckGoApplicationManager
  let events: RecordingDuckDuckGoAppleEventSender
  let coordinator: DuckDuckGoProcessCoordinator

  convenience init(
    compatibility: DuckDuckGoBuildCompatibility,
    existingManagedPIDs: [Int32] = [],
    unmanagedPIDs: [Int32] = [],
    managedSnapshotLaunchDateOffset: TimeInterval = 0,
    managedProcessIsTerminated: Bool = false,
    eventErrorCode: Int? = nil,
    activationSucceeds: Bool = true,
    launchError: TestFailure? = nil,
    waitError: TestFailure? = nil,
    storeFailure: FailingDuckDuckGoManagedStateStore.Failure? = nil,
    terminationSucceeds: Bool = true,
    removesSnapshotWhenTerminationFails: Bool = false,
    keepsSnapshotAfterSuccessfulTermination: Bool = false,
    launchedBundleIdentifier: String? = DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
    suspendsLaunch: Bool = false
  ) throws {
    try self.init(
      compatibilityChecker: StubDuckDuckGoCompatibility(value: compatibility),
      existingManagedPIDs: existingManagedPIDs,
      unmanagedPIDs: unmanagedPIDs,
      managedSnapshotLaunchDateOffset: managedSnapshotLaunchDateOffset,
      managedProcessIsTerminated: managedProcessIsTerminated,
      eventErrorCode: eventErrorCode,
      activationSucceeds: activationSucceeds,
      launchError: launchError,
      waitError: waitError,
      storeFailure: storeFailure,
      terminationSucceeds: terminationSucceeds,
      removesSnapshotWhenTerminationFails: removesSnapshotWhenTerminationFails,
      keepsSnapshotAfterSuccessfulTermination: keepsSnapshotAfterSuccessfulTermination,
      launchedBundleIdentifier: launchedBundleIdentifier,
      suspendsLaunch: suspendsLaunch
    )
  }

  init(
    compatibilityChecker: any DuckDuckGoBuildCompatibilityChecking,
    existingManagedPIDs: [Int32] = [],
    unmanagedPIDs: [Int32] = [],
    managedSnapshotLaunchDateOffset: TimeInterval = 0,
    managedProcessIsTerminated: Bool = false,
    eventErrorCode: Int? = nil,
    activationSucceeds: Bool = true,
    launchError: TestFailure? = nil,
    waitError: TestFailure? = nil,
    storeFailure: FailingDuckDuckGoManagedStateStore.Failure? = nil,
    terminationSucceeds: Bool = true,
    removesSnapshotWhenTerminationFails: Bool = false,
    keepsSnapshotAfterSuccessfulTermination: Bool = false,
    launchedBundleIdentifier: String? = DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
    suspendsLaunch: Bool = false
  ) throws {
    root = FileManager.default.temporaryDirectory.appending(
      path: "PickVia-DuckDuckGo-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    executableURL = applicationURL.appending(path: "Contents/MacOS/DuckDuckGo")
    let launchDate = Date(timeIntervalSince1970: 1_234)
    var snapshots: [Int32: DuckDuckGoApplicationSnapshot] = [:]
    realStore = DuckDuckGoManagedStateStore(rootDirectory: root)

    for (index, existingManagedPID) in existingManagedPIDs.enumerated() {
      let session = try realStore.prepareHome()
      let markerLaunchDate = launchDate.addingTimeInterval(Double(index))
      try realStore.save(
        DuckDuckGoManagedProcessMarker(
          identifier: session.identifier,
          processIdentifier: existingManagedPID,
          launchDate: markerLaunchDate,
          applicationPath: applicationURL.path,
          executablePath: executableURL.path
        ),
        for: session
      )
      snapshots[existingManagedPID] = DuckDuckGoProcessCoordinatorTests.makeSnapshot(
        processIdentifier: existingManagedPID,
        applicationURL: applicationURL,
        executableURL: executableURL,
        launchDate: markerLaunchDate.addingTimeInterval(
          managedSnapshotLaunchDateOffset
        ),
        isTerminated: managedProcessIsTerminated
      )
    }

    for (index, unmanagedPID) in unmanagedPIDs.enumerated() {
      snapshots[unmanagedPID] = DuckDuckGoProcessCoordinatorTests.makeSnapshot(
        processIdentifier: unmanagedPID,
        applicationURL: applicationURL,
        executableURL: executableURL,
        launchDate: launchDate.addingTimeInterval(Double(index) + 10)
      )
    }

    let nextPID: Int32 = existingManagedPIDs.isEmpty ? 7001 : 9001
    nextLaunch = DuckDuckGoProcessCoordinatorTests.makeSnapshot(
      processIdentifier: nextPID,
      applicationURL: applicationURL,
      executableURL: executableURL,
      launchDate: launchDate.addingTimeInterval(20),
      bundleIdentifier: launchedBundleIdentifier
    )
    applications = RecordingDuckDuckGoApplicationManager(
      snapshots: snapshots,
      nextLaunch: nextLaunch,
      activationSucceeds: activationSucceeds,
      terminationSucceeds: terminationSucceeds,
      removesSnapshotOnTermination: !keepsSnapshotAfterSuccessfulTermination
        && (terminationSucceeds || removesSnapshotWhenTerminationFails),
      launchError: launchError,
      waitError: waitError,
      suspendsLaunch: suspendsLaunch
    )
    events = RecordingDuckDuckGoAppleEventSender(errorCode: eventErrorCode)
    let store = FailingDuckDuckGoManagedStateStore(
      underlying: realStore,
      failure: storeFailure
    )
    coordinator = DuckDuckGoProcessCoordinator(
      compatibilityChecker: compatibilityChecker,
      applications: applications,
      events: events,
      stateStore: store
    )
  }

  func sessionDirectoryNames() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
  }

  func removeRoot() {
    try? FileManager.default.removeItem(at: root)
  }
}

private enum TestFailure: Error, Equatable, Sendable {
  case launch
  case save
  case wait
}

extension Collection {
  fileprivate var only: Element? {
    count == 1 ? first : nil
  }
}
