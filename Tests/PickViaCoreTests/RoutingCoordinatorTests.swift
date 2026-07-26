import Foundation
import XCTest

@testable import PickViaCore

final class RoutingCoordinatorTests: XCTestCase {
  func testMutableSnapshotExcludesEnabledMailTargetForDualCapabilityApplication() {
    let application = RoutedApplication(
      id: "com.google.Chrome",
      displayName: "Google Chrome",
      bundleIdentifier: "com.google.Chrome",
      capabilities: [
        .browser(family: .chromium, isAvailable: true),
        .mail(isAvailable: true),
      ],
      applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")
    )
    let webTarget = BrowserTarget(
      id: "com.google.Chrome||normal",
      browserID: application.id,
      label: "Google Chrome",
      profileIdentifier: nil,
      profileDisplayName: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available
    )
    let mailTarget = RouteTarget(
      id: RouteTarget.mailID(bundleIdentifier: application.bundleIdentifier),
      applicationID: application.id,
      label: "Google Chrome Mail",
      isEnabled: true,
      sortOrder: 1,
      origin: .detected,
      availability: .available,
      capability: .mail
    )
    let provider = MutableTargetSnapshot()
    provider.publish(
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        applications: [application],
        targets: [webTarget, mailTarget]
      )
    )

    let snapshot = provider.availableSnapshot(for: .web)

    XCTAssertEqual(snapshot.applications.map(\.id), [application.id])
    XCTAssertEqual(snapshot.targets.map(\.id), [webTarget.id])
  }

  func testMutableSnapshotIncludesOnlyEnabledAvailableMailTargetsForAvailableApplications() {
    let availableApplication = RoutedApplication(
      id: "com.example.Mail",
      displayName: "Mail",
      bundleIdentifier: "com.example.Mail",
      capabilities: [.mail(isAvailable: true)],
      applicationURL: URL(fileURLWithPath: "/Applications/Mail.app")
    )
    let unavailableApplication = RoutedApplication(
      id: "com.example.MissingMail",
      displayName: "Missing Mail",
      bundleIdentifier: "com.example.MissingMail",
      capabilities: [.mail(isAvailable: false)],
      applicationURL: URL(fileURLWithPath: "/Applications/Missing Mail.app")
    )
    func mailTarget(
      id: String,
      applicationID: String,
      isEnabled: Bool = true,
      availability: TargetAvailability = .available
    ) -> RouteTarget {
      RouteTarget(
        id: id,
        applicationID: applicationID,
        label: id,
        isEnabled: isEnabled,
        sortOrder: 0,
        origin: .detected,
        availability: availability,
        capability: .mail
      )
    }
    let expected = mailTarget(id: "mail", applicationID: availableApplication.id)
    let provider = MutableTargetSnapshot()
    provider.publish(
      PickViaConfig(
        schemaVersion: PickViaConfig.currentSchemaVersion,
        applications: [availableApplication, unavailableApplication],
        targets: [
          expected,
          mailTarget(
            id: "disabled", applicationID: availableApplication.id, isEnabled: false),
          mailTarget(
            id: "unavailable",
            applicationID: availableApplication.id,
            availability: .unavailable
          ),
          mailTarget(id: "missing-app", applicationID: unavailableApplication.id),
          BrowserTarget(
            id: "web",
            browserID: availableApplication.id,
            label: "Web",
            profileIdentifier: nil,
            profileDisplayName: nil,
            mode: .normal,
            isEnabled: true,
            sortOrder: 0,
            origin: .detected,
            availability: .available
          ),
        ]
      )
    )

    let snapshot = provider.availableSnapshot(for: .mail)

    XCTAssertEqual(snapshot.applications, [availableApplication])
    XCTAssertEqual(snapshot.targets, [expected])
  }

  func testValidatorAcceptsUppercaseHTTPScheme() throws {
    let input = try XCTUnwrap(URL(string: "HTTP://example.com/path"))

    XCTAssertEqual(try URLValidator.validate(input), ValidatedRoute(kind: .web, url: input))
  }

  func testValidatorAcceptsHTTPSWithUnicodeAndEscapedPath() throws {
    let input = try XCTUnwrap(
      URL(string: "https://example.com/%E8%B7%AF%E5%BE%84/hello%20world")
    )

    XCTAssertEqual(try URLValidator.validate(input), ValidatedRoute(kind: .web, url: input))
  }

  func testValidatorRejectsRelativeURL() throws {
    let input = try XCTUnwrap(URL(string: "relative/path"))

    XCTAssertThrowsError(try URLValidator.validate(input))
  }

  func testValidatorRejectsHTTPURLWithoutHost() throws {
    let input = try XCTUnwrap(URL(string: "https:///path"))

    XCTAssertThrowsError(try URLValidator.validate(input))
  }

  func testValidatorRejectsFileURL() {
    XCTAssertThrowsError(
      try URLValidator.validate(URL(fileURLWithPath: "/tmp/example"))
    )
  }

  func testValidatorClassifiesMailtoWithoutRequiringAHost() throws {
    let input = try XCTUnwrap(URL(string: "MAILTO:person@example.com?subject=Private"))

    XCTAssertEqual(try URLValidator.validate(input), ValidatedRoute(kind: .mail, url: input))
  }

  func testValidatorAcceptsEmptyMailComposeRequestUnchanged() throws {
    let input = try XCTUnwrap(URL(string: "mailto:"))

    XCTAssertEqual(try URLValidator.validate(input), ValidatedRoute(kind: .mail, url: input))
  }

  @MainActor
  func testEnqueuePresentsOnlyFirstRequestAndPreservesFIFOOrder() {
    let chooser = ChooserSpy()
    let coordinator = makeCoordinator(chooser: chooser)

    coordinator.enqueue(URL(string: "https://one.example")!)
    coordinator.enqueue(URL(string: "https://two.example")!)

    XCTAssertEqual(coordinator.currentRequest?.url.host, "one.example")
    XCTAssertEqual(chooser.presentedHosts, ["one.example"])
  }

  @MainActor
  func testCancelRemovesCurrentRequestAndPresentsNextRequest() {
    let chooser = ChooserSpy()
    let launcher = LauncherStub()
    let coordinator = makeCoordinator(chooser: chooser, launcher: launcher)
    coordinator.enqueue(URL(string: "https://one.example")!)
    coordinator.enqueue(URL(string: "https://two.example")!)

    coordinator.cancelCurrent()

    XCTAssertEqual(coordinator.currentRequest?.url.host, "two.example")
    XCTAssertEqual(chooser.presentedHosts, ["one.example", "two.example"])
    XCTAssertEqual(chooser.dismissCallCount, 1)
    XCTAssertTrue(launcher.launches.isEmpty)
  }

  @MainActor
  func testMixedWebAndMailRequestsRemainFIFO() {
    let chooser = ChooserSpy()
    let coordinator = makeCoordinator(chooser: chooser, snapshots: .webAndMail)

    coordinator.enqueue(URL(string: "https://one.example")!)
    coordinator.enqueue(URL(string: "mailto:person@example.com")!)
    coordinator.cancelCurrent()

    XCTAssertEqual(chooser.presentedKinds, [.web, .mail])
  }

  @MainActor
  func testSuccessfulLaunchRemovesCurrentRequestAndPresentsNextRequest() async {
    let chooser = ChooserSpy()
    let launcher = LauncherStub()
    let coordinator = makeCoordinator(chooser: chooser, launcher: launcher)
    coordinator.enqueue(URL(string: "https://one.example")!)
    coordinator.enqueue(URL(string: "https://two.example")!)

    await coordinator.selected(targetID: "target-1")

    XCTAssertEqual(launcher.launches.map(\.url.host), ["one.example"])
    XCTAssertEqual(launcher.launches.map(\.application.id), ["browser-1"])
    XCTAssertEqual(launcher.launches.map(\.target.id), ["target-1"])
    XCTAssertEqual(coordinator.currentRequest?.url.host, "two.example")
    XCTAssertEqual(chooser.presentedHosts, ["one.example", "two.example"])
    XCTAssertNil(coordinator.currentError)
  }

  @MainActor
  func testSuccessfulLaunchOfOnlyRequestReturnsCoordinatorToIdle() async {
    let chooser = ChooserSpy()
    let coordinator = makeCoordinator(chooser: chooser)
    coordinator.enqueue(URL(string: "https://one.example")!)

    await coordinator.selected(targetID: "target-1")

    XCTAssertNil(coordinator.currentRequest)
    XCTAssertNil(coordinator.currentError)
    XCTAssertEqual(chooser.dismissCallCount, 1)
  }

  @MainActor
  func testFailedLaunchKeepsCurrentRequestAndDoesNotAdvanceQueue() async {
    let chooser = ChooserSpy()
    let launcher = LauncherStub(result: .failure(TestError.failed))
    let coordinator = makeCoordinator(chooser: chooser, launcher: launcher)
    coordinator.enqueue(URL(string: "https://one.example")!)
    coordinator.enqueue(URL(string: "https://two.example")!)

    await coordinator.selected(targetID: "target-1")

    XCTAssertEqual(coordinator.currentRequest?.url.host, "one.example")
    XCTAssertEqual(chooser.presentedHosts, ["one.example", "one.example"])
    XCTAssertEqual(
      coordinator.currentError,
      LaunchFailure(message: "Could not open the selected browser target.")
    )
    XCTAssertEqual(
      chooser.presentedErrors.last??.message,
      "Could not open the selected browser target."
    )
    XCTAssertFalse(coordinator.currentError?.message.contains("one.example") ?? true)
    XCTAssertFalse(coordinator.currentError?.message.contains("failed") ?? true)
  }

  @MainActor
  func testLaunchFailedSanitizesFailureAndRePresentsCurrentRequest() {
    let chooser = ChooserSpy()
    let coordinator = makeCoordinator(chooser: chooser)
    coordinator.enqueue(URL(string: "https://one.example")!)
    let unsafeFailure = LaunchFailure(
      message: "Process failed for https://one.example: raw internal details"
    )

    coordinator.launchFailed(unsafeFailure)

    XCTAssertEqual(coordinator.currentRequest?.url.host, "one.example")
    XCTAssertEqual(
      coordinator.currentError,
      LaunchFailure(message: "Could not open the selected browser target.")
    )
    XCTAssertEqual(chooser.presentedHosts, ["one.example", "one.example"])
    XCTAssertEqual(
      chooser.presentedErrors.last!,
      LaunchFailure(message: "Could not open the selected browser target.")
    )
  }

  @MainActor
  func testMailLaunchFailureUsesRouteSpecificSanitizedCopy() {
    let chooser = ChooserSpy()
    let coordinator = makeCoordinator(chooser: chooser, snapshots: .webAndMail)
    coordinator.enqueue(URL(string: "mailto:person@example.com?body=private")!)

    coordinator.launchFailed(
      LaunchFailure(message: "Workspace exposed person@example.com and private body")
    )

    XCTAssertEqual(
      coordinator.currentError,
      LaunchFailure(message: "Could not open the selected mail app.")
    )
    XCTAssertEqual(
      chooser.presentedErrors.last!,
      LaunchFailure(message: "Could not open the selected mail app.")
    )
  }

  @MainActor
  func testBrowserTargetSelectedForMailFailsClosedWithoutLaunching() async {
    let chooser = ChooserSpy()
    let launcher = LauncherStub()
    let coordinator = makeCoordinator(
      chooser: chooser,
      launcher: launcher,
      snapshots: .browserTargetForMail
    )
    coordinator.enqueue(URL(string: "mailto:person@example.com")!)

    await coordinator.selected(targetID: TargetStub.webTarget.id)

    XCTAssertTrue(launcher.launches.isEmpty)
    XCTAssertEqual(
      coordinator.currentError,
      LaunchFailure(message: "Could not open the selected mail app.")
    )
  }

  @MainActor
  func testMailTargetSelectedForWebFailsClosedWithoutLaunching() async {
    let chooser = ChooserSpy()
    let launcher = LauncherStub()
    let coordinator = makeCoordinator(
      chooser: chooser,
      launcher: launcher,
      snapshots: .mailTargetForWeb
    )
    coordinator.enqueue(URL(string: "https://one.example")!)

    await coordinator.selected(targetID: TargetStub.mailTarget.id)

    XCTAssertTrue(launcher.launches.isEmpty)
    XCTAssertEqual(
      coordinator.currentError,
      LaunchFailure(message: "Could not open the selected browser target.")
    )
  }

  @MainActor
  func testSelectionAndCancellationAreIgnoredWhileLaunchIsInFlight() async {
    let chooser = ChooserSpy()
    let launcher = SuspendingFirstLauncher()
    let coordinator = RoutingCoordinator(
      targetProvider: TargetStub.one,
      chooser: chooser,
      launcher: launcher
    )
    coordinator.enqueue(URL(string: "https://one.example")!)
    coordinator.enqueue(URL(string: "https://two.example")!)
    let firstSelection = Task {
      await coordinator.selected(targetID: "target-1")
    }
    await launcher.waitUntilFirstLaunchStarts()

    await coordinator.selected(targetID: "target-1")
    coordinator.cancelCurrent()

    let launchCount = await launcher.launchCount
    XCTAssertEqual(launchCount, 1)
    XCTAssertEqual(coordinator.currentRequest?.url.host, "one.example")
    XCTAssertEqual(chooser.presentedHosts, ["one.example"])

    await launcher.resumeFirstLaunch()
    await firstSelection.value

    XCTAssertEqual(coordinator.currentRequest?.url.host, "two.example")
    XCTAssertEqual(chooser.presentedHosts, ["one.example", "two.example"])
  }

  @MainActor
  func testFailedLaunchClearsInFlightGuardAndAllowsRetry() async {
    let chooser = ChooserSpy()
    let launcher = SequencedLauncherStub(
      results: [.failure(TestError.failed), .success(())]
    )
    let coordinator = RoutingCoordinator(
      targetProvider: TargetStub.one,
      chooser: chooser,
      launcher: launcher
    )
    coordinator.enqueue(URL(string: "https://one.example")!)

    await coordinator.selected(targetID: "target-1")
    await coordinator.selected(targetID: "target-1")

    XCTAssertEqual(launcher.launchCount, 2)
    XCTAssertNil(coordinator.currentRequest)
    XCTAssertNil(coordinator.currentError)
  }

  @MainActor
  func testEmptyTargetSnapshotStillPresentsRecoveryChooser() {
    let chooser = ChooserSpy()
    let coordinator = RoutingCoordinator(
      targetProvider: TargetStub(snapshot: .init(applications: [], targets: [])),
      chooser: chooser,
      launcher: LauncherStub()
    )

    coordinator.enqueue(URL(string: "https://one.example")!)

    XCTAssertEqual(chooser.presentedHosts, ["one.example"])
    XCTAssertEqual(chooser.presentedApplicationCounts, [0])
    XCTAssertEqual(chooser.presentedTargetCounts, [0])
    XCTAssertEqual(coordinator.currentRequest?.url.host, "one.example")
  }

  @MainActor
  func testRefreshRePresentsQueuedRequestWithUpdatedAuthoritativeSnapshot() {
    let provider = MutableTargetSnapshot()
    let chooser = ChooserSpy()
    let coordinator = RoutingCoordinator(
      targetProvider: provider,
      chooser: chooser,
      launcher: LauncherStub()
    )
    coordinator.enqueue(URL(string: "https://one.example")!)
    provider.publish(
      PickViaConfig(
        schemaVersion: 1,
        applications: TargetStub.one.webSnapshot.applications,
        targets: TargetStub.one.webSnapshot.targets
      )
    )

    coordinator.refreshCurrentPresentation()

    XCTAssertEqual(chooser.presentedHosts, ["one.example", "one.example"])
    XCTAssertEqual(chooser.presentedTargetCounts, [0, 1])
    XCTAssertEqual(coordinator.currentRequest?.url.host, "one.example")
  }

  @MainActor
  private func makeCoordinator(
    chooser: ChooserSpy,
    launcher: LauncherStub = LauncherStub(),
    snapshots: TargetStub = .one
  ) -> RoutingCoordinator {
    RoutingCoordinator(
      targetProvider: snapshots,
      chooser: chooser,
      launcher: launcher
    )
  }
}

private enum TestError: Error {
  case failed
}

private struct TargetStub: TargetProviding {
  let webSnapshot: RoutingTargetSnapshot
  let mailSnapshot: RoutingTargetSnapshot

  static let webApplication = BrowserApplication(
    id: "browser-1",
    family: .chromium,
    displayName: "Browser",
    bundleIdentifier: "com.example.browser",
    applicationURL: URL(fileURLWithPath: "/Applications/Browser.app"),
    executableURL: nil,
    isAvailable: true
  )

  static let webTarget = BrowserTarget(
    id: "target-1",
    browserID: webApplication.id,
    label: "Default",
    profileIdentifier: nil,
    profileDisplayName: nil,
    mode: .normal,
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: .available
  )

  static let mailApplication = RoutedApplication(
    id: "mail-1",
    displayName: "Mail",
    bundleIdentifier: "com.example.mail",
    capabilities: [.mail(isAvailable: true)],
    applicationURL: URL(fileURLWithPath: "/Applications/Mail.app")
  )

  static let mailTarget = RouteTarget(
    id: "mail-target-1",
    applicationID: mailApplication.id,
    label: "Mail",
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: .available,
    capability: .mail
  )

  static let webSnapshot = RoutingTargetSnapshot(
    applications: [webApplication],
    targets: [webTarget]
  )

  static let mailSnapshot = RoutingTargetSnapshot(
    applications: [mailApplication],
    targets: [mailTarget]
  )

  static let one = TargetStub(
    webSnapshot: webSnapshot,
    mailSnapshot: .init(applications: [], targets: [])
  )

  static let webAndMail = TargetStub(
    webSnapshot: webSnapshot,
    mailSnapshot: mailSnapshot
  )

  static let browserTargetForMail = TargetStub(
    webSnapshot: webSnapshot,
    mailSnapshot: RoutingTargetSnapshot(
      applications: [
        webApplication
      ],
      targets: [
        webTarget
      ]
    )
  )

  static let mailTargetForWeb = TargetStub(
    webSnapshot: mailSnapshot,
    mailSnapshot: mailSnapshot
  )

  init(
    snapshot: RoutingTargetSnapshot
  ) {
    webSnapshot = snapshot
    mailSnapshot = .init(applications: [], targets: [])
  }

  init(
    webSnapshot: RoutingTargetSnapshot,
    mailSnapshot: RoutingTargetSnapshot
  ) {
    self.webSnapshot = webSnapshot
    self.mailSnapshot = mailSnapshot
  }

  func availableSnapshot(for kind: RouteKind) -> RoutingTargetSnapshot {
    switch kind {
    case .web: webSnapshot
    case .mail: mailSnapshot
    }
  }
}

@MainActor
private final class ChooserSpy: ChooserPresenting {
  private(set) var presentedHosts: [String?] = []
  private(set) var presentedKinds: [RouteKind] = []
  private(set) var presentedApplicationCounts: [Int] = []
  private(set) var presentedTargetCounts: [Int] = []
  private(set) var presentedErrors: [LaunchFailure?] = []
  private(set) var dismissCallCount = 0

  func present(
    request: RoutingRequest,
    applications: [BrowserApplication],
    targets: [BrowserTarget],
    error: LaunchFailure?,
    onSelection: @escaping (BrowserTarget.ID) -> Void,
    onCancel: @escaping () -> Void
  ) {
    presentedHosts.append(request.url.host)
    presentedKinds.append(request.kind)
    presentedApplicationCounts.append(applications.count)
    presentedTargetCounts.append(targets.count)
    presentedErrors.append(error)
  }

  func dismiss() {
    dismissCallCount += 1
  }
}

private final class LauncherStub: RouteLaunching, @unchecked Sendable {
  struct Launch {
    let url: URL
    let application: BrowserApplication
    let target: BrowserTarget
  }

  private let result: Result<Void, Error>
  private(set) var launches: [Launch] = []

  init(result: Result<Void, Error> = .success(())) {
    self.result = result
  }

  func launch(
    url: URL,
    application: BrowserApplication,
    target: BrowserTarget
  ) async throws {
    launches.append(Launch(url: url, application: application, target: target))
    try result.get()
  }
}

private actor SuspendingFirstLauncher: RouteLaunching {
  private(set) var launchCount = 0
  private var firstLaunchContinuation: CheckedContinuation<Void, Never>?
  private var firstLaunchStartWaiters: [CheckedContinuation<Void, Never>] = []

  func launch(
    url: URL,
    application: BrowserApplication,
    target: BrowserTarget
  ) async throws {
    launchCount += 1
    guard launchCount == 1 else { return }

    let waiters = firstLaunchStartWaiters
    firstLaunchStartWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      firstLaunchContinuation = continuation
    }
  }

  func waitUntilFirstLaunchStarts() async {
    if launchCount > 0 { return }
    await withCheckedContinuation { continuation in
      firstLaunchStartWaiters.append(continuation)
    }
  }

  func resumeFirstLaunch() {
    firstLaunchContinuation?.resume()
    firstLaunchContinuation = nil
  }
}

private final class SequencedLauncherStub: RouteLaunching, @unchecked Sendable {
  private var results: [Result<Void, Error>]
  private(set) var launchCount = 0

  init(results: [Result<Void, Error>]) {
    self.results = results
  }

  func launch(
    url: URL,
    application: BrowserApplication,
    target: BrowserTarget
  ) async throws {
    launchCount += 1
    try results.removeFirst().get()
  }
}
