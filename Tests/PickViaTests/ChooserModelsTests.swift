import PickViaCore
import XCTest

@testable import PickVia

final class ChooserModelsTests: XCTestCase {
  func testBrowserWithOneTargetIsDirectRow() {
    let presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work]
    )

    XCTAssertEqual(
      presentation.groups,
      [.direct(browserID: "chrome", row: .target("work", shortcut: .number(1)))]
    )
  }

  func testMultipleTargetsGroupUnderBrowserAndReceiveShortcuts() {
    let presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal]
    )

    XCTAssertEqual(
      presentation.groups,
      [
        .group(
          browserID: "chrome",
          rows: [
            .target("work", shortcut: .number(1)),
            .target("personal", shortcut: .number(2)),
          ]
        )
      ]
    )
  }

  func testDisabledUnavailableAndMissingBrowserTargetsAreOmitted() {
    let presentation = makePresentation(
      applications: [Fixtures.chrome, Fixtures.missingBrowser],
      targets: [
        Fixtures.work,
        Fixtures.target(id: "disabled", isEnabled: false),
        Fixtures.target(id: "unavailable", availability: .unavailable),
        Fixtures.target(id: "missing-app", browserID: "missing"),
        Fixtures.target(id: "missing-browser", browserID: "missing-browser"),
      ]
    )

    XCTAssertEqual(presentation.rows, [.target("work", shortcut: .number(1))])
    XCTAssertEqual(
      presentation.groups,
      [.direct(browserID: "chrome", row: .target("work", shortcut: .number(1)))]
    )
  }

  func testTargetSortOrderIsStableForTies() {
    let presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [
        Fixtures.target(id: "later", sortOrder: 2),
        Fixtures.target(id: "tie-a", sortOrder: 1),
        Fixtures.target(id: "tie-b", sortOrder: 1),
        Fixtures.target(id: "first", sortOrder: 0),
      ]
    )

    XCTAssertEqual(
      presentation.rows.map(\.targetID),
      ["first", "tie-a", "tie-b", "later"]
    )
  }

  func testShortcutsUseNumbersThenLettersAndStopAfterZ() {
    let targets = (0..<36).map {
      Fixtures.target(id: "target-\($0)", sortOrder: $0)
    }
    let presentation = makePresentation(applications: [Fixtures.chrome], targets: targets)

    XCTAssertEqual(presentation.rows[0].shortcut, .number(1))
    XCTAssertEqual(presentation.rows[8].shortcut, .number(9))
    XCTAssertEqual(presentation.rows[9].shortcut, .letter("A"))
    XCTAssertEqual(presentation.rows[34].shortcut, .letter("Z"))
    XCTAssertNil(presentation.rows[35].shortcut)
    XCTAssertEqual(
      presentation.rows.compactMap { $0.shortcut?.label },
      (1...9).map(String.init) + Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
    )
  }

  func testShortcutParserAcceptsOnlyASCIINumbersAndLetters() {
    XCTAssertEqual(ChooserShortcut.parse("1"), .number(1))
    XCTAssertEqual(ChooserShortcut.parse("9"), .number(9))
    XCTAssertEqual(ChooserShortcut.parse("A"), .letter("A"))
    XCTAssertEqual(ChooserShortcut.parse("Z"), .letter("Z"))
    XCTAssertEqual(ChooserShortcut.parse("a"), .letter("A"))
    XCTAssertEqual(ChooserShortcut.parse("z"), .letter("Z"))

    for character: Character in ["١", "１", "ı", "0", "-"] {
      XCTAssertNil(ChooserShortcut.parse(character), "Unexpected shortcut for \(character)")
    }
    XCTAssertNil(ChooserShortcut.parse(nil))
  }

  func testFilteringOccursBeforeShortcutAssignmentWithoutGaps() {
    var targets = (0..<10).map {
      Fixtures.target(id: "target-\($0)", sortOrder: $0 + 1)
    }
    targets.append(Fixtures.target(id: "disabled", isEnabled: false, sortOrder: 0))
    targets.append(
      Fixtures.target(id: "unavailable", sortOrder: 0, availability: .unavailable)
    )

    let presentation = makePresentation(applications: [Fixtures.chrome], targets: targets)

    XCTAssertEqual(presentation.rows.first?.shortcut, .number(1))
    XCTAssertEqual(presentation.rows.last?.shortcut, .letter("A"))
  }

  func testPresentationStartsNeutralAndReturnDoesNothing() {
    let presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal]
    )

    XCTAssertNil(presentation.selectedIndex)
    XCTAssertEqual(presentation.handle(.returnKey), .none)
  }

  func testDownFromNeutralSelectsFirstThenWraps() {
    var presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal]
    )

    presentation.moveSelection(.down)
    XCTAssertEqual(presentation.selectedIndex, 0)
    presentation.moveSelection(.up)
    XCTAssertEqual(presentation.selectedIndex, 1)
    presentation.moveSelection(.down)
    XCTAssertEqual(presentation.selectedIndex, 0)
  }

  func testUpFromNeutralSelectsLast() {
    var presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal]
    )

    presentation.moveSelection(.up)

    XCTAssertEqual(presentation.selectedIndex, 1)
  }

  func testReturnSelectsExplicitCurrentRowAndEscapeCancels() {
    var presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal]
    )
    presentation.moveSelection(.down)
    presentation.moveSelection(.down)

    XCTAssertEqual(presentation.handle(.returnKey), .select("personal"))
    XCTAssertEqual(presentation.handle(.escape), .cancel)
  }

  func testShortcutKeySelectsMatchingNumberAndLetter() {
    let targets = (0..<10).map {
      Fixtures.target(id: "target-\($0)", sortOrder: $0)
    }
    let presentation = makePresentation(applications: [Fixtures.chrome], targets: targets)

    XCTAssertEqual(presentation.handle(.shortcut(.number(2))), .select("target-1"))
    XCTAssertEqual(presentation.handle(.shortcut(.letter("A"))), .select("target-9"))
    XCTAssertEqual(presentation.handle(.shortcut(.letter("Z"))), .none)
  }

  func testTargetAfterZRemainsReachableWithArrowAndReturn() {
    let targets = (0..<36).map {
      Fixtures.target(id: "target-\($0)", sortOrder: $0)
    }
    var presentation = makePresentation(applications: [Fixtures.chrome], targets: targets)

    XCTAssertNil(presentation.rows[35].shortcut)
    presentation.moveSelection(.up)
    XCTAssertEqual(presentation.handle(.returnKey), .select("target-35"))
  }

  func testErrorStatePreservesCurrentSelection() {
    var presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal]
    )
    presentation.moveSelection(.down)
    presentation.moveSelection(.down)

    presentation.setError(LaunchFailure(message: "Safe launch error"))

    XCTAssertEqual(presentation.selectedIndex, 1)
    XCTAssertEqual(presentation.errorMessage, "Safe launch error")
  }

  func testMakePreservesExplicitSelectionAcrossRerender() {
    let presentation = ChooserPresentation.make(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal],
      error: LaunchFailure(message: "Safe launch error"),
      preservingSelection: "personal"
    )

    XCTAssertEqual(presentation.selectedIndex, 1)
  }

  func testMakePreservesNeutralSelectionAcrossRerender() {
    let presentation = ChooserPresentation.make(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal],
      error: LaunchFailure(message: "Safe launch error"),
      preservingSelection: nil
    )

    XCTAssertNil(presentation.selectedIndex)
  }

  func testDisplayURLRemovesCredentials() throws {
    let request = RoutingRequest(
      url: try XCTUnwrap(URL(string: "https://person:secret@example.com/private?q=1")))

    let presentation = ChooserPresentation.make(
      request: request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work]
    )

    XCTAssertEqual(presentation.displayURL, "https://example.com/private?q=1")
  }

  private func makePresentation(
    applications: [BrowserApplication],
    targets: [BrowserTarget]
  ) -> ChooserPresentation {
    ChooserPresentation.make(
      request: Fixtures.request,
      applications: applications,
      targets: targets
    )
  }
}

@MainActor
final class ChooserPanelControllerTests: XCTestCase {
  func testPointerOutsideScreensCentersPanelOnMainVisibleFrame() throws {
    let mainScreen = try XCTUnwrap(NSScreen.main)
    let frames = NSScreen.screens.map(\.frame)
    let outside = NSPoint(
      x: (frames.map(\.minX).min() ?? 0) - 10_000,
      y: (frames.map(\.maxY).max() ?? 0) + 10_000
    )
    let controller = ChooserPanelController(pointerLocationProvider: { outside })

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    let panelFrame = controller.panelFrameForTesting

    let expectedOrigin = ChooserPanelLayout.centeredOrigin(
      panelSize: panelFrame.size,
      visibleFrame: mainScreen.visibleFrame
    )
    XCTAssertEqual(panelFrame.origin.x, expectedOrigin.x, accuracy: 0.5)
    XCTAssertEqual(panelFrame.origin.y, expectedOrigin.y, accuracy: 0.5)
    controller.dismiss()
  }

  func testPresentationCapturesPointerOnceAndKeepsItAcrossRerender() {
    var points = [NSPoint(x: 100, y: 700), NSPoint(x: 900, y: 100)]
    let controller = ChooserPanelController(pointerLocationProvider: { points.removeFirst() })

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    XCTAssertEqual(controller.pointerAnchorForCurrentPresentation, NSPoint(x: 100, y: 700))

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal],
      error: LaunchFailure(message: "Safe launch error"),
      onSelection: { _ in },
      onCancel: {}
    )

    XCTAssertEqual(controller.pointerAnchorForCurrentPresentation, NSPoint(x: 100, y: 700))
    XCTAssertEqual(points.count, 1)
    XCTAssertEqual(
      controller.panelContentSizeForTesting.width,
      ChooserDensity.compact.metrics.contentWidth
    )
    controller.dismiss()
    XCTAssertNil(controller.pointerAnchorForCurrentPresentation)
  }

  func testDensityMetricsMatchEveryApprovedPresetValue() {
    let expected: [(ChooserDensity, ChooserMetrics)] = [
      (
        .compact,
        ChooserMetrics(
          contentWidth: 340,
          outerPadding: 12,
          mainSpacing: 8,
          groupSpacing: 3,
          rowHorizontalPadding: 8,
          rowVerticalPadding: 3,
          headerHorizontalPadding: 8,
          headerVerticalPadding: 1
        )
      ),
      (
        .balanced,
        ChooserMetrics(
          contentWidth: 380,
          outerPadding: 14,
          mainSpacing: 10,
          groupSpacing: 6,
          rowHorizontalPadding: 10,
          rowVerticalPadding: 5,
          headerHorizontalPadding: 10,
          headerVerticalPadding: 2
        )
      ),
      (
        .spacious,
        ChooserMetrics(
          contentWidth: 420,
          outerPadding: 18,
          mainSpacing: 14,
          groupSpacing: 9,
          rowHorizontalPadding: 12,
          rowVerticalPadding: 8,
          headerHorizontalPadding: 12,
          headerVerticalPadding: 4
        )
      ),
    ]

    for (density, metrics) in expected {
      XCTAssertEqual(density.metrics.contentWidth, metrics.contentWidth, density.title)
      XCTAssertEqual(density.metrics.outerPadding, metrics.outerPadding, density.title)
      XCTAssertEqual(density.metrics.mainSpacing, metrics.mainSpacing, density.title)
      XCTAssertEqual(density.metrics.groupSpacing, metrics.groupSpacing, density.title)
      XCTAssertEqual(
        density.metrics.rowHorizontalPadding,
        metrics.rowHorizontalPadding,
        density.title
      )
      XCTAssertEqual(density.metrics.rowVerticalPadding, metrics.rowVerticalPadding, density.title)
      XCTAssertEqual(
        density.metrics.headerHorizontalPadding,
        metrics.headerHorizontalPadding,
        density.title
      )
      XCTAssertEqual(
        density.metrics.headerVerticalPadding,
        metrics.headerVerticalPadding,
        density.title
      )
    }
  }

  func testEveryDensityWidthIsResolvedForNewRequestsAndRetainedForRerender() {
    let preference = DensityPreference(value: .compact)
    let controller = ChooserPanelController(densityProvider: { preference.value })

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    XCTAssertEqual(controller.densityForCurrentPresentation, .compact)
    XCTAssertEqual(controller.panelContentSizeForTesting.width, 340)

    preference.value = .balanced
    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: LaunchFailure(message: "Safe launch error"),
      onSelection: { _ in },
      onCancel: {}
    )
    XCTAssertEqual(controller.densityForCurrentPresentation, .compact)

    controller.dismiss()
    controller.present(
      request: RoutingRequest(url: URL(string: "https://example.com/new")!),
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    XCTAssertEqual(controller.densityForCurrentPresentation, .balanced)
    XCTAssertEqual(controller.panelContentSizeForTesting.width, 380)
    controller.dismiss()

    preference.value = .spacious
    controller.present(
      request: RoutingRequest(url: URL(string: "https://example.com/spacious")!),
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    XCTAssertEqual(controller.densityForCurrentPresentation, .spacious)
    XCTAssertEqual(controller.panelContentSizeForTesting.width, 420)
    controller.dismiss()
  }

  func testSameRequestErrorRerenderKeepsExistingPanelOrigin() throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let pointer = NSPoint(
      x: screen.visibleFrame.midX,
      y: screen.visibleFrame.minY + 250
    )
    let controller = ChooserPanelController(pointerLocationProvider: { pointer })

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    let initialOrigin = controller.panelFrameForTesting.origin

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: LaunchFailure(
        message: String(repeating: "The browser could not open this link safely. ", count: 12)
      ),
      onSelection: { _ in },
      onCancel: {}
    )

    XCTAssertEqual(controller.panelFrameForTesting.origin, initialOrigin)
    controller.dismiss()
  }

  func testSameRequestErrorRerenderStaysWithinTopScreenEdge() throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let pointer = NSPoint(
      x: screen.visibleFrame.midX,
      y: screen.visibleFrame.maxY - 30
    )
    let controller = ChooserPanelController(pointerLocationProvider: { pointer })

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    let initialOrigin = controller.panelFrameForTesting.origin

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: LaunchFailure(
        message: String(repeating: "The browser could not open this link safely. ", count: 30)
      ),
      onSelection: { _ in },
      onCancel: {}
    )
    let rerenderedFrame = controller.panelFrameForTesting

    XCTAssertEqual(rerenderedFrame.origin, initialOrigin)
    XCTAssertLessThanOrEqual(
      rerenderedFrame.maxY,
      screen.visibleFrame.maxY - ChooserPanelLayout.screenMargin + 1
    )
    controller.dismiss()
  }

  func testHostedChooserGrowsForFittingRowsAndCapsOversizedTargetList() throws {
    let screen = try XCTUnwrap(NSScreen.main)
    let controller = ChooserPanelController(
      pointerLocationProvider: { NSPoint(x: screen.frame.midX, y: screen.frame.midY) }
    )

    func presentedHeight(targetCount: Int) -> CGFloat {
      let targets = (0..<targetCount).map {
        Fixtures.target(id: "target-\($0)", sortOrder: $0)
      }
      controller.present(
        request: Fixtures.request,
        applications: [Fixtures.chrome],
        targets: targets,
        error: nil,
        onSelection: { _ in },
        onCancel: {}
      )
      let height = controller.panelContentSizeForTesting.height
      controller.dismiss()
      return height
    }

    let oneRowHeight = presentedHeight(targetCount: 1)
    let sixRowHeight = presentedHeight(targetCount: 6)
    let oversizedHeight = presentedHeight(targetCount: 80)
    let maximumHeight = ChooserPanelLayout.maximumPanelHeight(in: screen.visibleFrame)

    XCTAssertGreaterThan(sixRowHeight, oneRowHeight)
    XCTAssertGreaterThan(oversizedHeight, sixRowHeight)
    XCTAssertEqual(oversizedHeight, maximumHeight, accuracy: 1)
  }

  func testNewRequestCapturesANewPointerAnchor() {
    var points = [NSPoint(x: 100, y: 700), NSPoint(x: 900, y: 100)]
    let controller = ChooserPanelController(pointerLocationProvider: { points.removeFirst() })

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    let nextRequest = RoutingRequest(url: URL(string: "https://example.com/next")!)
    controller.present(
      request: nextRequest,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )

    XCTAssertEqual(controller.pointerAnchorForCurrentPresentation, NSPoint(x: 900, y: 100))
    XCTAssertTrue(points.isEmpty)
    controller.dismiss()
  }

  func testQueuedRoutingRequestCoalescesChooserLifecycleBeforeWizardRetry() async throws {
    let wizardPresented = expectation(description: "wizard retry presents")
    let retryObserver = ProfileAccessRetryObserver(
      onWizardPresent: { wizardPresented.fulfill() }
    )
    let controller = ChooserPanelController(
      onPresentationChange: { isPresented in
        retryObserver.chooserPresentationDidChange(isPresented)
      }
    )
    let coordinator = RoutingCoordinator(
      targetProvider: ChooserTargetProviderStub(),
      chooser: controller,
      launcher: ChooserLauncherStub()
    )
    coordinator.enqueue(URL(string: "https://example.com/first")!)
    coordinator.enqueue(URL(string: "https://example.com/second")!)

    NSApp.sendEvent(try makeKeyEvent(keyCode: 53, characters: "\u{1b}"))
    await Task.yield()

    XCTAssertEqual(retryObserver.presentationChanges, [true])
    XCTAssertEqual(retryObserver.wizardPresentCallCount, 0)
    XCTAssertEqual(coordinator.currentRequest?.url, URL(string: "https://example.com/second"))

    NSApp.sendEvent(try makeKeyEvent(keyCode: 53, characters: "\u{1b}"))
    await fulfillment(of: [wizardPresented], timeout: 1)

    XCTAssertEqual(retryObserver.presentationChanges, [true, false])
    XCTAssertEqual(retryObserver.wizardPresentCallCount, 1)
    XCTAssertNil(coordinator.currentRequest)
  }

  func testPresentationLifecycleReportsOnlyActualPresentationTransition() async {
    var changes: [Bool] = []
    let presentationEnded = expectation(description: "presentation ended")
    let controller = ChooserPanelController(
      onPresentationChange: {
        changes.append($0)
        if !$0 { presentationEnded.fulfill() }
      }
    )

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    controller.dismiss()
    controller.dismiss()

    XCTAssertEqual(changes, [true])
    await fulfillment(of: [presentationEnded], timeout: 1)
    XCTAssertEqual(changes, [true, false])
  }

  func testResignCancellationReportsPresentationEnded() async {
    var changes: [Bool] = []
    let presentationEnded = expectation(description: "presentation ended")
    let controller = ChooserPanelController(
      onPresentationChange: {
        changes.append($0)
        if !$0 { presentationEnded.fulfill() }
      }
    )
    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )

    controller.resignKeyForTesting()
    await fulfillment(of: [presentationEnded], timeout: 1)

    XCTAssertEqual(changes, [true, false])
  }

  func testWindowCloseCancelsAndReportsPresentationEnded() async {
    var cancelCount = 0
    var changes: [Bool] = []
    let presentationEnded = expectation(description: "presentation ended")
    let controller = ChooserPanelController(
      onPresentationChange: {
        changes.append($0)
        if !$0 { presentationEnded.fulfill() }
      }
    )
    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: { cancelCount += 1 }
    )

    controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    await fulfillment(of: [presentationEnded], timeout: 1)

    XCTAssertEqual(cancelCount, 1)
    XCTAssertEqual(changes, [true, false])
  }

  func testSuccessfulSelectionDismissReportsPresentationEnded() async throws {
    var changes: [Bool] = []
    let presentationEnded = expectation(description: "presentation ended")
    var controller: ChooserPanelController!
    controller = ChooserPanelController(
      onPresentationChange: {
        changes.append($0)
        if !$0 { presentationEnded.fulfill() }
      }
    )
    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in controller.dismiss() },
      onCancel: {}
    )
    NSApp.sendEvent(try makeKeyEvent(keyCode: 125, characters: ""))
    NSApp.sendEvent(try makeKeyEvent(keyCode: 36, characters: "\r"))
    await fulfillment(of: [presentationEnded], timeout: 1)

    XCTAssertEqual(changes, [true, false])
  }

  private func makeKeyEvent(keyCode: UInt16, characters: String) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
      )
    )
  }

  func testOpeningBrowserSettingsSuppressesResignCancellationAndRetainsPresentation() {
    var cancelCount = 0
    let controller = ChooserPanelController(openBrowserSettings: {})
    controller.present(
      request: Fixtures.request,
      applications: [],
      targets: [],
      error: nil,
      onSelection: { _ in },
      onCancel: { cancelCount += 1 }
    )

    controller.showBrowserSettings()
    controller.resignKeyForTesting()

    XCTAssertEqual(cancelCount, 0)
    XCTAssertTrue(controller.hasActivePresentation)
    controller.dismiss()
  }

  func testOrdinaryResignKeyCancelsCurrentPresentation() {
    var cancelCount = 0
    let controller = ChooserPanelController()
    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: { cancelCount += 1 }
    )

    controller.resignKeyForTesting()

    XCTAssertEqual(cancelCount, 1)
    XCTAssertFalse(controller.hasActivePresentation)
  }

  func testRepeatedPresentDismissRemovesKeyboardMonitor() {
    let controller = ChooserPanelController()

    for _ in 0..<2 {
      controller.present(
        request: Fixtures.request,
        applications: [Fixtures.chrome],
        targets: [Fixtures.work],
        error: nil,
        onSelection: { _ in },
        onCancel: {}
      )
      XCTAssertTrue(controller.isKeyboardMonitorInstalled)
      controller.dismiss()
      XCTAssertFalse(controller.isKeyboardMonitorInstalled)
    }
  }

  func testShortcutParserAcceptsNumbersAndCaseInsensitiveLetters() {
    XCTAssertEqual(
      ChooserPanelController.shortcutKey(character: "1", modifiers: []),
      .shortcut(.number(1))
    )
    XCTAssertEqual(
      ChooserPanelController.shortcutKey(character: "a", modifiers: []),
      .shortcut(.letter("A"))
    )
    XCTAssertEqual(
      ChooserPanelController.shortcutKey(character: "A", modifiers: []),
      .shortcut(.letter("A"))
    )
  }

  func testShortcutParserAllowsShiftAndCapsLockForLetters() {
    XCTAssertEqual(
      ChooserPanelController.shortcutKey(character: "A", modifiers: .shift),
      .shortcut(.letter("A"))
    )
    XCTAssertEqual(
      ChooserPanelController.shortcutKey(character: "A", modifiers: .capsLock),
      .shortcut(.letter("A"))
    )
  }

  func testShortcutParserRejectsCommandOptionControlAndUnsupportedCharacters() {
    for modifier in [NSEvent.ModifierFlags.command, .option, .control] {
      XCTAssertNil(
        ChooserPanelController.shortcutKey(character: "A", modifiers: modifier)
      )
    }
    XCTAssertNil(ChooserPanelController.shortcutKey(character: "0", modifiers: []))
    XCTAssertNil(ChooserPanelController.shortcutKey(character: "-", modifiers: []))
    XCTAssertNil(ChooserPanelController.shortcutKey(character: nil, modifiers: []))
  }

  func testRecoveryActionsUseInjectedDependenciesWithoutPresentingWindow() {
    let clipboard = ClipboardSpy()
    var settingsCallCount = 0
    let controller = ChooserPanelController(
      clipboard: clipboard,
      openBrowserSettings: { settingsCallCount += 1 }
    )

    controller.copyURL(Fixtures.request.url)
    controller.showBrowserSettings()

    XCTAssertEqual(clipboard.strings, ["https://example.com/a"])
    XCTAssertEqual(settingsCallCount, 1)
  }

  func testURLVisibilityIsResolvedForEachPresentation() {
    let preference = URLVisibilityPreference(value: true)
    let controller = ChooserPanelController(showsURLProvider: { preference.value })

    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    XCTAssertTrue(controller.showsURLForCurrentPresentation)
    controller.dismiss()

    preference.value = false
    controller.present(
      request: Fixtures.request,
      applications: [Fixtures.chrome],
      targets: [Fixtures.work],
      error: nil,
      onSelection: { _ in },
      onCancel: {}
    )
    XCTAssertFalse(controller.showsURLForCurrentPresentation)
    controller.dismiss()
  }

  func testBrowserRecoverySelectsBrowserSettingsBeforeOpeningSettings() {
    let navigation = SettingsNavigation()
    var destinationWhenOpened: SettingsDestination?
    let recovery = BrowserSettingsRecovery(
      navigation: navigation,
      openSettings: { destinationWhenOpened = navigation.destination }
    )
    let controller = ChooserPanelController(openBrowserSettings: recovery.open)

    controller.showBrowserSettings()

    XCTAssertEqual(navigation.destination, .browsers)
    XCTAssertEqual(destinationWhenOpened, .browsers)
  }
}

@MainActor
private final class ProfileAccessRetryObserver {
  private(set) var presentationChanges: [Bool] = []
  private(set) var wizardPresentCallCount = 0
  private let onWizardPresent: @MainActor () -> Void

  init(onWizardPresent: @escaping @MainActor () -> Void) {
    self.onWizardPresent = onWizardPresent
  }

  func chooserPresentationDidChange(_ isPresented: Bool) {
    presentationChanges.append(isPresented)
    if !isPresented {
      wizardPresentCallCount += 1
      onWizardPresent()
    }
  }
}

private struct ChooserTargetProviderStub: TargetProviding {
  func availableSnapshot() -> RoutingTargetSnapshot {
    RoutingTargetSnapshot(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work]
    )
  }
}

private struct ChooserLauncherStub: BrowserLaunching {
  func launch(
    url: URL,
    application: BrowserApplication,
    target: BrowserTarget
  ) async throws {}
}

@MainActor
private final class URLVisibilityPreference {
  var value: Bool

  init(value: Bool) {
    self.value = value
  }
}

@MainActor
private final class DensityPreference {
  var value: ChooserDensity

  init(value: ChooserDensity) {
    self.value = value
  }
}

@MainActor
private final class ClipboardSpy: ClipboardWriting {
  private(set) var strings: [String] = []

  func write(_ string: String) {
    strings.append(string)
  }
}

private enum Fixtures {
  static let request = RoutingRequest(url: URL(string: "https://example.com/a")!)

  static let chrome = BrowserApplication(
    id: "chrome",
    family: .chromium,
    displayName: "Google Chrome",
    bundleIdentifier: "com.google.Chrome",
    applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
    executableURL: nil,
    isAvailable: true
  )

  static let missingBrowser = BrowserApplication(
    id: "missing-browser",
    family: .firefox,
    displayName: "Missing Browser",
    bundleIdentifier: "example.missing",
    applicationURL: URL(fileURLWithPath: "/Applications/Missing.app"),
    executableURL: nil,
    isAvailable: false
  )

  static let work = target(id: "work", label: "Work", sortOrder: 0)
  static let personal = target(id: "personal", label: "Personal", sortOrder: 1)

  static func target(
    id: String,
    browserID: String = "chrome",
    label: String? = nil,
    isEnabled: Bool = true,
    sortOrder: Int = 0,
    availability: BrowserTargetAvailability = .available
  ) -> BrowserTarget {
    BrowserTarget(
      id: id,
      browserID: browserID,
      label: label ?? id,
      profileIdentifier: id,
      profileDisplayName: label ?? id,
      mode: .normal,
      isEnabled: isEnabled,
      sortOrder: sortOrder,
      origin: .detected,
      availability: availability
    )
  }
}
