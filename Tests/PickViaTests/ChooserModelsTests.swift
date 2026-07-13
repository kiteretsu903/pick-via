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
      [.direct(browserID: "chrome", row: .target("work", shortcut: "1"))]
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
            .target("work", shortcut: "1"),
            .target("personal", shortcut: "2"),
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

    XCTAssertEqual(presentation.rows, [.target("work", shortcut: "1")])
    XCTAssertEqual(
      presentation.groups,
      [.direct(browserID: "chrome", row: .target("work", shortcut: "1"))]
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

  func testOnlyFirstNineRowsReceiveNumberShortcuts() {
    let targets = (0..<11).map {
      Fixtures.target(id: "target-\($0)", sortOrder: $0)
    }
    let presentation = makePresentation(applications: [Fixtures.chrome], targets: targets)

    XCTAssertEqual(
      presentation.rows.map(\.shortcut),
      ["1", "2", "3", "4", "5", "6", "7", "8", "9", nil, nil]
    )
  }

  func testArrowMovementWrapsAtBothEnds() {
    var presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal]
    )

    XCTAssertEqual(presentation.selectedIndex, 0)
    presentation.moveSelection(.up)
    XCTAssertEqual(presentation.selectedIndex, 1)
    presentation.moveSelection(.down)
    XCTAssertEqual(presentation.selectedIndex, 0)
  }

  func testReturnSelectsCurrentRowAndEscapeCancels() {
    var presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal]
    )
    presentation.moveSelection(.down)

    XCTAssertEqual(presentation.handle(.returnKey), .select("personal"))
    XCTAssertEqual(presentation.handle(.escape), .cancel)
  }

  func testNumberKeySelectsMatchingShortcut() {
    let presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal]
    )

    XCTAssertEqual(presentation.handle(.number(2)), .select("personal"))
    XCTAssertEqual(presentation.handle(.number(9)), .none)
  }

  func testErrorStatePreservesCurrentSelection() {
    var presentation = makePresentation(
      applications: [Fixtures.chrome],
      targets: [Fixtures.work, Fixtures.personal]
    )
    presentation.moveSelection(.down)

    presentation.setError(LaunchFailure(message: "Safe launch error"))

    XCTAssertEqual(presentation.selectedIndex, 1)
    XCTAssertEqual(presentation.errorMessage, "Safe launch error")
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
    let returnKey = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36
      )
    )

    NSApp.sendEvent(returnKey)
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

  func testModifiedNumberShortcutsRejectCommandOptionAndControl() {
    XCTAssertEqual(
      ChooserPanelController.numberShortcut(character: "1", modifiers: []),
      .number(1)
    )
    for modifier in [NSEvent.ModifierFlags.command, .option, .control] {
      XCTAssertNil(
        ChooserPanelController.numberShortcut(character: "1", modifiers: modifier)
      )
    }
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
