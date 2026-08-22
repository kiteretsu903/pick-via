#if PICKVIA_E2E_AUTOMATION
  import Foundation
  import PickViaCore
  import XCTest

  @testable import PickVia

  final class E2EControlTests: XCTestCase {
    func testExactAvailableWebTargetIsSelected() {
      let decision = E2ETargetDecision.evaluate(
        control: Fixtures.control,
        requestKind: .web,
        applications: [Fixtures.edge],
        targets: [Fixtures.edgeNormal]
      )

      XCTAssertEqual(decision, .select(Fixtures.edgeNormal.id))
    }

    func testEveryUnsafeTargetShapeIsRejectedWithoutFallback() {
      let cases:
        [(
          RouteKind,
          [RoutedApplication],
          [RouteTarget],
          E2ESelectionOutcome
        )] = [
          (.mail, [Fixtures.edge], [Fixtures.edgeNormal], .nonWebRequest),
          (.web, [], [Fixtures.edgeNormal], .targetBrowserMismatch),
          (.web, [Fixtures.edge], [], .targetMissing),
          (
            .web,
            [Fixtures.edge],
            [Fixtures.edgeNormal, Fixtures.edgeNormal],
            .targetAmbiguous
          ),
          (.web, [Fixtures.edge], [Fixtures.disabledEdge], .targetDisabled),
          (.web, [Fixtures.edge], [Fixtures.unavailableEdge], .targetUnavailable),
          (.web, [Fixtures.chrome], [Fixtures.edgeNormal], .targetBrowserMismatch),
          (.web, [Fixtures.edge], [Fixtures.edgePrivateShape], .targetModeMismatch),
          (.web, [Fixtures.edge], [Fixtures.edgeMailShape], .targetModeMismatch),
        ]

      for (kind, applications, targets, outcome) in cases {
        XCTAssertEqual(
          E2ETargetDecision.evaluate(
            control: Fixtures.control,
            requestKind: kind,
            applications: applications,
            targets: targets
          ),
          .reject(outcome)
        )
      }
    }

    func testTargetApplicationMustMatchExpectedBundleAndBeAvailableForWeb() {
      XCTAssertEqual(
        E2ETargetDecision.evaluate(
          control: Fixtures.control,
          requestKind: .web,
          applications: [Fixtures.edgeWithWrongBundle],
          targets: [Fixtures.edgeNormal]
        ),
        .reject(.targetBrowserMismatch)
      )
      XCTAssertEqual(
        E2ETargetDecision.evaluate(
          control: Fixtures.control,
          requestKind: .web,
          applications: [Fixtures.unavailableEdgeApplication],
          targets: [Fixtures.edgeNormal]
        ),
        .reject(.targetBrowserMismatch)
      )
    }

    func testLoaderAcceptsOnlyTheExactValidControlShape() {
      let control = E2EControl.load(environment: Fixtures.environment)

      XCTAssertEqual(control, Fixtures.control)
    }

    func testLoaderRejectsEveryMissingEmptyOrWhitespaceOnlyRequiredValue() {
      for key in Fixtures.requiredKeys {
        var missing = Fixtures.environment
        missing.removeValue(forKey: key)
        XCTAssertNil(E2EControl.load(environment: missing), "missing \(key)")

        var empty = Fixtures.environment
        empty[key] = ""
        XCTAssertNil(E2EControl.load(environment: empty), "empty \(key)")

        var whitespace = Fixtures.environment
        whitespace[key] = " \t "
        XCTAssertNil(E2EControl.load(environment: whitespace), "whitespace \(key)")
      }
    }

    func testLoaderRejectsControlBytesInEveryRequiredValue() {
      for key in Fixtures.requiredKeys {
        var environment = Fixtures.environment
        environment[key] = environment[key]! + "\n"
        XCTAssertNil(E2EControl.load(environment: environment), "control byte in \(key)")
      }
    }

    func testLoaderRejectsInvalidModeAndNonce() {
      for mode in ["incognito", "NORMAL", "normal "] {
        var environment = Fixtures.environment
        environment[E2EEnvironmentKey.mode] = mode
        XCTAssertNil(E2EControl.load(environment: environment), "mode \(mode)")
      }

      for nonce in [
        "short",
        "session.with.dot",
        "session/with/slash",
        String(repeating: "a", count: 65),
      ] {
        var environment = Fixtures.environment
        environment[E2EEnvironmentKey.sessionNonce] = nonce
        XCTAssertNil(E2EControl.load(environment: environment), "nonce \(nonce)")
      }
    }

    func testLoaderEnforcesUTF8ByteLimits() {
      var targetTooLong = Fixtures.environment
      targetTooLong[E2EEnvironmentKey.targetID] = String(repeating: "é", count: 257)
      XCTAssertNil(E2EControl.load(environment: targetTooLong))

      var bundleTooLong = Fixtures.environment
      bundleTooLong[E2EEnvironmentKey.bundleIdentifier] = String(repeating: "b", count: 256)
      XCTAssertNil(E2EControl.load(environment: bundleTooLong))

      var supportTooLong = Fixtures.environment
      supportTooLong[E2EEnvironmentKey.supportDirectory] =
        "/private/tmp/pickvia-e2e-" + String(repeating: "s", count: 1_000)
      XCTAssertNil(E2EControl.load(environment: supportTooLong))

      var fifoTooLong = Fixtures.environment
      fifoTooLong[E2EEnvironmentKey.statusFIFO] =
        Fixtures.supportPath + "/" + String(repeating: "f", count: 1_000)
      XCTAssertNil(E2EControl.load(environment: fifoTooLong))
    }

    func testLoaderRejectsSupportDirectoriesOutsideDedicatedPrivateTemporaryRoot() {
      for supportPath in [
        "relative/pickvia-e2e-session",
        "/tmp/pickvia-e2e-session",
        "/private/tmp/not-pickvia-e2e-session",
        "/private/tmp/pickvia-e2e-",
        "/private/tmp/pickvia-e2e-session/nested",
        "/private/tmp/pickvia-e2e-session/../escaped",
      ] {
        var environment = Fixtures.environment
        environment[E2EEnvironmentKey.supportDirectory] = supportPath
        environment[E2EEnvironmentKey.statusFIFO] = supportPath + "/status.fifo"
        XCTAssertNil(E2EControl.load(environment: environment), supportPath)
      }
    }

    func testLoaderRejectsFIFOOutsideOrEqualToSupportDirectory() {
      for fifoPath in [
        "relative/status.fifo",
        Fixtures.supportPath,
        "/private/tmp/status.fifo",
        "/private/tmp/pickvia-e2e-session-sibling/status.fifo",
        Fixtures.supportPath + "/../status.fifo",
      ] {
        var environment = Fixtures.environment
        environment[E2EEnvironmentKey.statusFIFO] = fifoPath
        XCTAssertNil(E2EControl.load(environment: environment), fifoPath)
      }
    }

    func testLoaderAllowsFIFOInNestedDirectoryWithinSupportRoot() {
      var environment = Fixtures.environment
      environment[E2EEnvironmentKey.statusFIFO] =
        Fixtures.supportPath + "/status/channel.fifo"

      XCTAssertEqual(
        E2EControl.load(environment: environment)?.statusFIFO.path,
        Fixtures.supportPath + "/status/channel.fifo"
      )
    }
  }

  private enum Fixtures {
    static let edgeBundleIdentifier = "com.microsoft.edgemac"
    static let supportPath = "/private/tmp/pickvia-e2e-session_0123456789"
    static let fifoPath = supportPath + "/status.fifo"

    static let control = E2EControl(
      targetID: "com.microsoft.edgemac||normal",
      expectedBundleIdentifier: edgeBundleIdentifier,
      expectedMode: .normal,
      sessionNonce: "session_0123456789",
      applicationSupportDirectory: URL(fileURLWithPath: supportPath, isDirectory: true),
      statusFIFO: URL(fileURLWithPath: fifoPath)
    )

    static let environment = [
      E2EEnvironmentKey.targetID: control.targetID,
      E2EEnvironmentKey.bundleIdentifier: control.expectedBundleIdentifier,
      E2EEnvironmentKey.mode: control.expectedMode.rawValue,
      E2EEnvironmentKey.sessionNonce: control.sessionNonce,
      E2EEnvironmentKey.supportDirectory: supportPath,
      E2EEnvironmentKey.statusFIFO: fifoPath,
    ]

    static let requiredKeys = [
      E2EEnvironmentKey.targetID,
      E2EEnvironmentKey.bundleIdentifier,
      E2EEnvironmentKey.mode,
      E2EEnvironmentKey.sessionNonce,
      E2EEnvironmentKey.supportDirectory,
      E2EEnvironmentKey.statusFIFO,
    ]

    static let edge = application(
      id: edgeBundleIdentifier,
      bundleIdentifier: edgeBundleIdentifier,
      isAvailable: true
    )
    static let chrome = application(
      id: "com.google.Chrome",
      bundleIdentifier: "com.google.Chrome",
      isAvailable: true
    )
    static let edgeWithWrongBundle = application(
      id: edgeBundleIdentifier,
      bundleIdentifier: "com.microsoft.edgemac.Beta",
      isAvailable: true
    )
    static let unavailableEdgeApplication = application(
      id: edgeBundleIdentifier,
      bundleIdentifier: edgeBundleIdentifier,
      isAvailable: false
    )

    static let edgeNormal = target()
    static let disabledEdge = target(isEnabled: false)
    static let unavailableEdge = target(availability: .unavailable)
    static let edgePrivateShape = target(mode: .private)
    static let edgeMailShape = RouteTarget(
      id: control.targetID,
      applicationID: edge.id,
      label: "Synthetic target",
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available,
      capability: .mail
    )

    private static func application(
      id: String,
      bundleIdentifier: String,
      isAvailable: Bool
    ) -> RoutedApplication {
      RoutedApplication(
        id: id,
        family: .chromium,
        displayName: "Synthetic browser",
        bundleIdentifier: bundleIdentifier,
        applicationURL: URL(fileURLWithPath: "/Applications/Synthetic Browser.app"),
        executableURL: nil,
        isAvailable: isAvailable
      )
    }

    private static func target(
      mode: BrowserMode = .normal,
      isEnabled: Bool = true,
      availability: TargetAvailability = .available
    ) -> RouteTarget {
      RouteTarget(
        id: control.targetID,
        browserID: edge.id,
        label: "Synthetic target",
        profileIdentifier: nil,
        profileDisplayName: nil,
        mode: mode,
        isEnabled: isEnabled,
        sortOrder: 0,
        origin: .detected,
        availability: availability
      )
    }
  }
#endif
