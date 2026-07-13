import Foundation
import XCTest
@testable import PickViaCore

final class RoutingCoordinatorTests: XCTestCase {
    func testValidatorAcceptsUppercaseHTTPScheme() throws {
        let input = try XCTUnwrap(URL(string: "HTTP://example.com/path"))

        XCTAssertEqual(try URLValidator.validate(input), input)
    }

    func testValidatorAcceptsHTTPSWithUnicodeAndEscapedPath() throws {
        let input = try XCTUnwrap(
            URL(string: "https://example.com/%E8%B7%AF%E5%BE%84/hello%20world")
        )

        XCTAssertEqual(try URLValidator.validate(input), input)
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

    func testValidatorRejectsMailtoURL() throws {
        let input = try XCTUnwrap(URL(string: "mailto:person@example.com"))

        XCTAssertThrowsError(try URLValidator.validate(input))
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
    func testLaunchFailedPublishesFailureAndRePresentsCurrentRequest() {
        let chooser = ChooserSpy()
        let coordinator = makeCoordinator(chooser: chooser)
        coordinator.enqueue(URL(string: "https://one.example")!)
        let failure = LaunchFailure(message: "Safe message")

        coordinator.launchFailed(failure)

        XCTAssertEqual(coordinator.currentRequest?.url.host, "one.example")
        XCTAssertEqual(coordinator.currentError, failure)
        XCTAssertEqual(chooser.presentedHosts, ["one.example", "one.example"])
        XCTAssertEqual(chooser.presentedErrors.last!, failure)
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
    private func makeCoordinator(
        chooser: ChooserSpy,
        launcher: LauncherStub = LauncherStub()
    ) -> RoutingCoordinator {
        RoutingCoordinator(
            targetProvider: TargetStub.one,
            chooser: chooser,
            launcher: launcher
        )
    }
}

private enum TestError: Error {
    case failed
}

private struct TargetStub: TargetProviding {
    let snapshot: RoutingTargetSnapshot

    static let one = TargetStub(
        snapshot: RoutingTargetSnapshot(
            applications: [
                BrowserApplication(
                    id: "browser-1",
                    family: .chromium,
                    displayName: "Browser",
                    bundleIdentifier: "com.example.browser",
                    applicationURL: URL(fileURLWithPath: "/Applications/Browser.app"),
                    executableURL: nil,
                    isAvailable: true
                ),
            ],
            targets: [
                BrowserTarget(
                    id: "target-1",
                    browserID: "browser-1",
                    label: "Default",
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

    func availableSnapshot() -> RoutingTargetSnapshot {
        snapshot
    }
}

@MainActor
private final class ChooserSpy: ChooserPresenting {
    private(set) var presentedHosts: [String?] = []
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
        presentedApplicationCounts.append(applications.count)
        presentedTargetCounts.append(targets.count)
        presentedErrors.append(error)
    }

    func dismiss() {
        dismissCallCount += 1
    }
}

private final class LauncherStub: BrowserLaunching, @unchecked Sendable {
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
