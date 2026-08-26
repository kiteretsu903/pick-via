#if PICKVIA_E2E_AUTOMATION
  import Foundation
  import PickViaCore
  import XCTest

  @testable import PickVia

  @MainActor
  final class E2EChooserPresenterTests: XCTestCase {
    func testPresenterRendersWithInertCallbacksThenSelectsExactTargetOnce() async {
      let fixture = makeFixture()

      fixture.present()
      fixture.base.invokePresentedSelection("untrusted-target")
      fixture.base.invokePresentedCancel()
      XCTAssertTrue(fixture.selectedTargetIDs.isEmpty)
      XCTAssertEqual(fixture.cancelCallCount, 0)

      await Task.yield()

      XCTAssertEqual(fixture.base.presentCallCount, 1)
      XCTAssertEqual(fixture.selectedTargetIDs, [Fixtures.edgeNormal.id])
      XCTAssertEqual(fixture.status.outcomes, [.selected])
      XCTAssertEqual(fixture.events, ["status:selected", "selection"])
    }

    func testRepeatedPresentationOfSameRequestNeverSelectsOrReportsTwice() async {
      let fixture = makeFixture()

      fixture.present()
      fixture.present()
      await Task.yield()

      XCTAssertEqual(fixture.base.presentCallCount, 2)
      XCTAssertEqual(fixture.base.dismissCallCount, 1)
      XCTAssertEqual(fixture.selectedTargetIDs, [Fixtures.edgeNormal.id])
      XCTAssertEqual(fixture.status.outcomes, [.selected])
      XCTAssertEqual(fixture.cancelCallCount, 0)
    }

    func testNewRequestWithSameControlSelectsIndependently() async {
      let fixture = makeFixture()
      let secondRequest = RoutingRequest(
        id: UUID(),
        kind: .web,
        url: Fixtures.request.url
      )

      fixture.present()
      fixture.present(request: secondRequest)
      await Task.yield()

      XCTAssertEqual(
        fixture.selectedTargetIDs,
        [Fixtures.edgeNormal.id, Fixtures.edgeNormal.id]
      )
      XCTAssertEqual(fixture.status.outcomes, [.selected, .selected])
    }

    func testLaunchErrorPresentationReportsAndNeverRetriesSelection() async {
      let fixture = makeFixture()

      fixture.present()
      await Task.yield()
      fixture.present(error: LaunchFailure(message: "sanitized"))
      fixture.base.invokePresentedSelection(Fixtures.edgeNormal.id)
      fixture.base.invokePresentedCancel()
      await Task.yield()

      XCTAssertEqual(fixture.selectedTargetIDs, [Fixtures.edgeNormal.id])
      XCTAssertEqual(fixture.cancelCallCount, 0)
      XCTAssertEqual(fixture.status.outcomes, [.selected, .launchError])
      XCTAssertEqual(fixture.base.dismissCallCount, 1)
    }

    func testRepeatedLaunchErrorForSameRequestIsReportedOnceAndNeverSelects() async {
      let fixture = makeFixture()
      let error = LaunchFailure(message: "sanitized")

      fixture.present(error: error)
      fixture.present(error: error)
      await Task.yield()

      XCTAssertTrue(fixture.selectedTargetIDs.isEmpty)
      XCTAssertEqual(fixture.cancelCallCount, 0)
      XCTAssertEqual(fixture.status.outcomes, [.launchError])
      XCTAssertEqual(fixture.base.dismissCallCount, 2)
    }

    func testRejectedTargetDismissesBaseAndNeverFallsBack() async {
      let fixture = makeFixture(targets: [])

      fixture.present()
      fixture.base.invokePresentedSelection(Fixtures.edgeNormal.id)
      fixture.base.invokePresentedCancel()
      await Task.yield()

      XCTAssertTrue(fixture.selectedTargetIDs.isEmpty)
      XCTAssertEqual(fixture.cancelCallCount, 0)
      XCTAssertEqual(fixture.base.dismissCallCount, 1)
      XCTAssertEqual(fixture.status.outcomes, [.targetMissing])
    }

    func testRepeatedRejectedRequestDismissesWithoutReportingTwice() async {
      let fixture = makeFixture(targets: [])

      fixture.present()
      fixture.present()
      await Task.yield()

      XCTAssertTrue(fixture.selectedTargetIDs.isEmpty)
      XCTAssertEqual(fixture.status.outcomes, [.targetMissing])
      XCTAssertEqual(fixture.base.dismissCallCount, 2)
    }

    func testSelectedStatusFailureDismissesAndPermanentlyPreventsSelection() async {
      let fixture = makeFixture(statusSucceeds: false)

      fixture.present()
      fixture.present()
      await Task.yield()

      XCTAssertTrue(fixture.selectedTargetIDs.isEmpty)
      XCTAssertEqual(fixture.cancelCallCount, 0)
      XCTAssertEqual(fixture.status.outcomes, [.selected])
      XCTAssertEqual(fixture.base.dismissCallCount, 2)
    }

    func testMissingControlDismissesWithoutSelectingOrCancelling() async {
      let fixture = makeFixture(control: nil)

      fixture.present()
      fixture.base.invokePresentedSelection(Fixtures.edgeNormal.id)
      fixture.base.invokePresentedCancel()
      await Task.yield()

      XCTAssertTrue(fixture.selectedTargetIDs.isEmpty)
      XCTAssertEqual(fixture.cancelCallCount, 0)
      XCTAssertTrue(fixture.status.outcomes.isEmpty)
      XCTAssertEqual(fixture.base.dismissCallCount, 1)
    }

    func testDismissDelegatesToBase() {
      let base = E2EBaseChooserSpy()
      let presenter = E2EChooserPresenter(
        base: base,
        control: Fixtures.control,
        statusWriter: E2EStatusWriterSpy(succeeds: true)
      )

      presenter.dismiss()

      XCTAssertEqual(base.dismissCallCount, 1)
    }

    private func makeFixture(
      control: E2EControl? = Fixtures.control,
      targets: [RouteTarget] = [Fixtures.edgeNormal],
      statusSucceeds: Bool = true
    ) -> PresenterFixture {
      PresenterFixture(control: control, targets: targets, statusSucceeds: statusSucceeds)
    }
  }

  @MainActor
  private final class PresenterFixture {
    let base = E2EBaseChooserSpy()
    let status: E2EStatusWriterSpy
    let presenter: E2EChooserPresenter
    let targets: [RouteTarget]
    var selectedTargetIDs: [RouteTarget.ID] = []
    var cancelCallCount = 0
    var events: [String] = []

    init(
      control: E2EControl?,
      targets: [RouteTarget],
      statusSucceeds: Bool
    ) {
      self.targets = targets
      status = E2EStatusWriterSpy(succeeds: statusSucceeds)
      presenter = E2EChooserPresenter(base: base, control: control, statusWriter: status)
      status.onWrite = { [weak self] outcome in
        self?.events.append("status:\(outcome.rawValue)")
      }
    }

    func present(
      request: RoutingRequest = Fixtures.request,
      error: LaunchFailure? = nil
    ) {
      presenter.present(
        request: request,
        applications: [Fixtures.edge],
        targets: targets,
        error: error,
        onSelection: { [weak self] targetID in
          self?.events.append("selection")
          self?.selectedTargetIDs.append(targetID)
        },
        onCancel: { [weak self] in self?.cancelCallCount += 1 }
      )
    }
  }

  @MainActor
  private final class E2EBaseChooserSpy: ChooserPresenting {
    private(set) var presentCallCount = 0
    private(set) var dismissCallCount = 0
    private var onSelection: ((RouteTarget.ID) -> Void)?
    private var onCancel: (() -> Void)?

    func present(
      request: RoutingRequest,
      applications: [RoutedApplication],
      targets: [RouteTarget],
      error: LaunchFailure?,
      onSelection: @escaping (RouteTarget.ID) -> Void,
      onCancel: @escaping () -> Void
    ) {
      presentCallCount += 1
      self.onSelection = onSelection
      self.onCancel = onCancel
    }

    func dismiss() {
      dismissCallCount += 1
      onSelection = nil
      onCancel = nil
    }

    func invokePresentedSelection(_ targetID: RouteTarget.ID) {
      onSelection?(targetID)
    }

    func invokePresentedCancel() {
      onCancel?()
    }
  }

  private final class E2EStatusWriterSpy: E2EStatusWriting {
    let succeeds: Bool
    private(set) var outcomes: [E2ESelectionOutcome] = []
    var onWrite: ((E2ESelectionOutcome) -> Void)?

    init(succeeds: Bool) {
      self.succeeds = succeeds
    }

    func write(
      _ outcome: E2ESelectionOutcome,
      sessionNonce: String,
      to fifo: URL
    ) -> Bool {
      outcomes.append(outcome)
      onWrite?(outcome)
      return succeeds
    }
  }

  private enum Fixtures {
    static let bundleIdentifier = "com.microsoft.edgemac"
    static let request = RoutingRequest(
      id: UUID(uuidString: "F51BB41E-D1E5-4E34-9A39-E565646AD575")!,
      kind: .web,
      url: URL(string: "https://pickvia.invalid/e2e-request")!
    )
    static let control = E2EControl(
      targetID: edgeNormal.id,
      expectedBundleIdentifier: bundleIdentifier,
      expectedMode: .normal,
      sessionNonce: "session_0123456789",
      requestNonce: "request_0123456789",
      applicationSupportDirectory: URL(
        fileURLWithPath: "/private/tmp/pickvia-e2e-presenter",
        isDirectory: true
      ),
      statusFIFO: URL(fileURLWithPath: "/private/tmp/pickvia-e2e-presenter/status.fifo"),
      provenanceFIFO: URL(
        fileURLWithPath: "/private/tmp/pickvia-e2e-presenter/provenance.fifo"
      )
    )
    static let edge = BrowserApplication(
      id: bundleIdentifier,
      family: .chromium,
      displayName: "Synthetic Browser",
      bundleIdentifier: bundleIdentifier,
      applicationURL: URL(fileURLWithPath: "/Applications/Synthetic.app"),
      executableURL: URL(fileURLWithPath: "/Applications/Synthetic.app/Contents/MacOS/App"),
      isAvailable: true
    )
    static let edgeNormal = BrowserTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: bundleIdentifier,
        profileIdentifier: nil,
        mode: .normal
      ),
      browserID: bundleIdentifier,
      label: "Synthetic Browser",
      profileIdentifier: nil,
      profileDisplayName: nil,
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available
    )
  }
#endif
