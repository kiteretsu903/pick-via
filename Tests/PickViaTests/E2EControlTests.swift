#if PICKVIA_E2E_AUTOMATION
  import Darwin
  import Foundation
  import PickViaCore
  import XCTest

  @testable import PickVia

  final class E2EControlTests: XCTestCase {
    private var supportRoot: URL!
    private var cleanupURLs: [URL] = []

    override func setUpWithError() throws {
      supportRoot = URL(
        fileURLWithPath: "/private/tmp/pickvia-e2e-control-\(UUID().uuidString)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: supportRoot,
        withIntermediateDirectories: false
      )
      cleanupURLs = [supportRoot]
    }

    override func tearDownWithError() throws {
      for url in cleanupURLs.reversed() {
        let path = url.path
        let prefix = "/private/tmp/pickvia-e2e-"
        let suffix = path.dropFirst(prefix.count)
        guard
          path.hasPrefix(prefix),
          !suffix.isEmpty,
          !suffix.contains("/")
        else { continue }
        try FileManager.default.removeItem(at: url)
      }
      cleanupURLs = []
      supportRoot = nil
    }

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

    func testExactChromiumAndFirefoxProfileTargetsAreSelected() throws {
      let firefoxPath = try makeRealFirefoxProfileDirectory(label: "valid")
      let firefoxFixture = Fixtures.firefoxProfileFixture(profilePath: firefoxPath)
      for fixture in [Fixtures.edgeProfileFixture, firefoxFixture] {
        XCTAssertEqual(
          E2ETargetDecision.evaluate(
            control: fixture.control,
            requestKind: .web,
            applications: [fixture.application],
            targets: [fixture.target]
          ),
          .select(fixture.target.id)
        )
      }
    }

    func testFirefoxProfileRejectsEveryUnsafeLaunchPathShape() throws {
      let validPath = try makeRealFirefoxProfileDirectory(label: "expected")
      let validIdentity = FirefoxProfileIdentity.identifier(for: validPath)
      let validTargetID = BrowserCatalog.targetID(
        bundleIdentifier: Fixtures.firefoxBundleIdentifier,
        profileIdentifier: validIdentity,
        mode: .normal
      )
      let control = Fixtures.control(
        targetID: validTargetID,
        bundleIdentifier: Fixtures.firefoxBundleIdentifier
      )
      let otherPath = try makeRealFirefoxProfileDirectory(label: "other")
      let otherIdentity = FirefoxProfileIdentity.identifier(for: otherPath)
      let nonnormalizedPath =
        validPath.deletingLastPathComponent().path
        + "/nested/../"
        + validPath.lastPathComponent
      let targets = [
        Fixtures.firefoxProfileTarget(
          id: validTargetID,
          identity: validIdentity,
          launchPath: nil
        ),
        Fixtures.firefoxProfileTarget(
          id: validTargetID,
          identity: validIdentity,
          launchPath: "relative/profile"
        ),
        Fixtures.firefoxProfileTarget(
          id: validTargetID,
          identity: validIdentity,
          launchPath: nonnormalizedPath
        ),
        Fixtures.firefoxProfileTarget(
          id: validTargetID,
          identity: validIdentity,
          launchPath: otherPath.path
        ),
      ]

      for target in targets {
        assertShapeMismatch(
          E2ETargetDecision.evaluate(
            control: control,
            requestKind: .web,
            applications: [Fixtures.firefox],
            targets: [target]
          )
        )
      }

      let wrongIdentityTargetID = BrowserCatalog.targetID(
        bundleIdentifier: Fixtures.firefoxBundleIdentifier,
        profileIdentifier: otherIdentity,
        mode: .normal
      )
      assertShapeMismatch(
        E2ETargetDecision.evaluate(
          control: Fixtures.control(
            targetID: wrongIdentityTargetID,
            bundleIdentifier: Fixtures.firefoxBundleIdentifier
          ),
          requestKind: .web,
          applications: [Fixtures.firefox],
          targets: [
            Fixtures.firefoxProfileTarget(
              id: wrongIdentityTargetID,
              identity: otherIdentity,
              launchPath: validPath.path
            )
          ]
        )
      )
    }

    func testChromiumProfileRejectsAnyLaunchPath() {
      let fixture = Fixtures.edgeProfileFixture
      let target = Fixtures.target(
        id: fixture.target.id,
        browserID: fixture.application.id,
        profileIdentifier: fixture.target.profileIdentifier,
        profileDisplayName: fixture.target.profileDisplayName,
        profileIdentity: fixture.target.profileIdentity,
        profileLaunchPath: "/private/tmp/synthetic-chromium-profile"
      )

      assertShapeMismatch(
        E2ETargetDecision.evaluate(
          control: fixture.control,
          requestKind: .web,
          applications: [fixture.application],
          targets: [target]
        )
      )
    }

    func testCanonicalBrowserLevelIDRejectsEveryHiddenProfileField() {
      let targets = [
        Fixtures.target(profileIdentifier: "Default"),
        Fixtures.target(profileDisplayName: "Synthetic profile"),
        Fixtures.target(profileIdentity: "Default"),
        Fixtures.target(profileLaunchPath: "/private/tmp/synthetic-profile"),
      ]

      for target in targets {
        assertShapeMismatch(
          E2ETargetDecision.evaluate(
            control: Fixtures.control,
            requestKind: .web,
            applications: [Fixtures.edge],
            targets: [target]
          )
        )
      }
    }

    func testProfileTargetRejectsCanonicalIDAndIdentityMismatch() {
      let target = Fixtures.target(
        id: BrowserCatalog.targetID(
          bundleIdentifier: Fixtures.edgeBundleIdentifier,
          profileIdentifier: "Profile A",
          mode: .normal
        ),
        profileIdentifier: "Profile B",
        profileDisplayName: "Synthetic profile",
        profileIdentity: "Profile B"
      )
      let control = Fixtures.control(targetID: target.id)

      assertShapeMismatch(
        E2ETargetDecision.evaluate(
          control: control,
          requestKind: .web,
          applications: [Fixtures.edge],
          targets: [target]
        )
      )
    }

    func testChromiumProfileTargetRejectsDistinctLaunchIdentifierAndIdentity() {
      let identity = "Profile 1"
      let target = Fixtures.target(
        id: BrowserCatalog.targetID(
          bundleIdentifier: Fixtures.edgeBundleIdentifier,
          profileIdentifier: identity,
          mode: .normal
        ),
        profileIdentifier: "Different launch selector",
        profileDisplayName: "Synthetic profile",
        profileIdentity: identity
      )
      let control = Fixtures.control(targetID: target.id)

      assertShapeMismatch(
        E2ETargetDecision.evaluate(
          control: control,
          requestKind: .web,
          applications: [Fixtures.edge],
          targets: [target]
        )
      )
    }

    func testFirefoxProfileTargetRejectsNonOpaqueIdentity() {
      let identity = "not-an-opaque-firefox-identity"
      let target = Fixtures.target(
        id: BrowserCatalog.targetID(
          bundleIdentifier: Fixtures.firefoxBundleIdentifier,
          profileIdentifier: identity,
          mode: .normal
        ),
        browserID: Fixtures.firefoxBundleIdentifier,
        profileIdentifier: "Synthetic profile",
        profileDisplayName: "Synthetic profile",
        profileIdentity: identity
      )
      let control = Fixtures.control(
        targetID: target.id,
        bundleIdentifier: Fixtures.firefoxBundleIdentifier
      )

      assertShapeMismatch(
        E2ETargetDecision.evaluate(
          control: control,
          requestKind: .web,
          applications: [Fixtures.firefox],
          targets: [target]
        )
      )
    }

    func testManualAndUnsupportedProfileTargetsAreRejected() {
      let manualTarget = Fixtures.target(origin: .manual)
      assertShapeMismatch(
        E2ETargetDecision.evaluate(
          control: Fixtures.control,
          requestKind: .web,
          applications: [Fixtures.edge],
          targets: [manualTarget]
        )
      )

      let identity = "synthetic-profile"
      let operaTarget = Fixtures.target(
        id: BrowserCatalog.targetID(
          bundleIdentifier: Fixtures.operaBundleIdentifier,
          profileIdentifier: identity,
          mode: .normal
        ),
        browserID: Fixtures.operaBundleIdentifier,
        profileIdentifier: identity,
        profileDisplayName: "Synthetic profile",
        profileIdentity: identity
      )
      let operaControl = Fixtures.control(
        targetID: operaTarget.id,
        bundleIdentifier: Fixtures.operaBundleIdentifier
      )
      assertShapeMismatch(
        E2ETargetDecision.evaluate(
          control: operaControl,
          requestKind: .web,
          applications: [Fixtures.opera],
          targets: [operaTarget]
        )
      )
    }

    func testBrowserWithoutPrivateCapabilityRejectsPrivateTarget() {
      let target = Fixtures.target(
        id: BrowserCatalog.targetID(
          bundleIdentifier: Fixtures.operaBundleIdentifier,
          profileIdentifier: nil,
          mode: .private
        ),
        browserID: Fixtures.operaBundleIdentifier,
        mode: .private
      )
      let control = Fixtures.control(
        targetID: target.id,
        bundleIdentifier: Fixtures.operaBundleIdentifier,
        mode: .private
      )

      assertShapeMismatch(
        E2ETargetDecision.evaluate(
          control: control,
          requestKind: .web,
          applications: [Fixtures.opera],
          targets: [target]
        )
      )
    }

    func testApplicationIdentityBundleFamilyAndUniquenessMustAllMatch() {
      let aliasTarget = Fixtures.target(browserID: "edge-alias")
      let aliasApplication = Fixtures.application(
        id: "edge-alias",
        bundleIdentifier: Fixtures.edgeBundleIdentifier,
        family: .chromium,
        isAvailable: true
      )
      XCTAssertEqual(
        E2ETargetDecision.evaluate(
          control: Fixtures.control,
          requestKind: .web,
          applications: [aliasApplication],
          targets: [aliasTarget]
        ),
        .reject(.targetBrowserMismatch)
      )

      XCTAssertEqual(
        E2ETargetDecision.evaluate(
          control: Fixtures.control,
          requestKind: .web,
          applications: [Fixtures.edgeWithWrongFamily],
          targets: [Fixtures.edgeNormal]
        ),
        .reject(.targetBrowserMismatch)
      )

      XCTAssertEqual(
        E2ETargetDecision.evaluate(
          control: Fixtures.control,
          requestKind: .web,
          applications: [Fixtures.edge, Fixtures.edge],
          targets: [Fixtures.edgeNormal]
        ),
        .reject(.targetBrowserMismatch)
      )

      let unsupportedTarget = Fixtures.target(
        id: BrowserCatalog.targetID(
          bundleIdentifier: Fixtures.unsupportedBundleIdentifier,
          profileIdentifier: nil,
          mode: .normal
        ),
        browserID: Fixtures.unsupportedBundleIdentifier
      )
      let unsupportedControl = Fixtures.control(
        targetID: unsupportedTarget.id,
        bundleIdentifier: Fixtures.unsupportedBundleIdentifier
      )
      XCTAssertEqual(
        E2ETargetDecision.evaluate(
          control: unsupportedControl,
          requestKind: .web,
          applications: [Fixtures.unsupported],
          targets: [unsupportedTarget]
        ),
        .reject(.targetBrowserMismatch)
      )
    }

    func testLoaderAcceptsOnlyTheExactValidControlShape() {
      let control = E2EControl.load(environment: environment)

      XCTAssertEqual(control, expectedLoadedControl)
    }

    func testLoaderRejectsEveryMissingEmptyOrWhitespaceOnlyRequiredValue() {
      for key in Fixtures.requiredKeys {
        var missing = environment
        missing.removeValue(forKey: key)
        XCTAssertNil(E2EControl.load(environment: missing), "missing \(key)")

        var empty = environment
        empty[key] = ""
        XCTAssertNil(E2EControl.load(environment: empty), "empty \(key)")

        var whitespace = environment
        whitespace[key] = " \t "
        XCTAssertNil(E2EControl.load(environment: whitespace), "whitespace \(key)")
      }
    }

    func testLoaderRejectsControlBytesInEveryRequiredValue() {
      for key in Fixtures.requiredKeys {
        var invalidEnvironment = environment
        invalidEnvironment[key] = invalidEnvironment[key]! + "\n"
        XCTAssertNil(
          E2EControl.load(environment: invalidEnvironment),
          "control byte in \(key)"
        )
      }
    }

    func testLoaderRejectsInvalidModeAndNonce() {
      for mode in ["incognito", "NORMAL", "normal "] {
        var invalidEnvironment = environment
        invalidEnvironment[E2EEnvironmentKey.mode] = mode
        XCTAssertNil(E2EControl.load(environment: invalidEnvironment), "mode \(mode)")
      }

      for nonce in [
        "short",
        "session.with.dot",
        "session/with/slash",
        String(repeating: "a", count: 65),
      ] {
        var invalidEnvironment = environment
        invalidEnvironment[E2EEnvironmentKey.sessionNonce] = nonce
        XCTAssertNil(E2EControl.load(environment: invalidEnvironment), "nonce \(nonce)")
      }
    }

    func testLoaderEnforcesUTF8ByteLimits() {
      var targetTooLong = environment
      targetTooLong[E2EEnvironmentKey.targetID] = String(repeating: "é", count: 257)
      XCTAssertNil(E2EControl.load(environment: targetTooLong))

      var bundleTooLong = environment
      bundleTooLong[E2EEnvironmentKey.bundleIdentifier] = String(repeating: "b", count: 256)
      XCTAssertNil(E2EControl.load(environment: bundleTooLong))

      var supportTooLong = environment
      supportTooLong[E2EEnvironmentKey.supportDirectory] =
        "/private/tmp/pickvia-e2e-" + String(repeating: "s", count: 1_000)
      XCTAssertNil(E2EControl.load(environment: supportTooLong))

      var fifoTooLong = environment
      fifoTooLong[E2EEnvironmentKey.statusFIFO] =
        supportRoot.path + "/" + String(repeating: "f", count: 1_000)
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
        var invalidEnvironment = environment
        invalidEnvironment[E2EEnvironmentKey.supportDirectory] = supportPath
        invalidEnvironment[E2EEnvironmentKey.statusFIFO] = supportPath + "/status.fifo"
        XCTAssertNil(E2EControl.load(environment: invalidEnvironment), supportPath)
      }
    }

    func testLoaderRejectsFIFOOutsideOrEqualToSupportDirectory() {
      for fifoPath in [
        "relative/status.fifo",
        supportRoot.path,
        "/private/tmp/status.fifo",
        supportRoot.path + "-sibling/status.fifo",
        supportRoot.path + "/../status.fifo",
      ] {
        var invalidEnvironment = environment
        invalidEnvironment[E2EEnvironmentKey.statusFIFO] = fifoPath
        XCTAssertNil(E2EControl.load(environment: invalidEnvironment), fifoPath)
      }
    }

    func testLoaderRejectsNestedFIFOPathIncludingSymlinkAncestorEscape() throws {
      let nested = supportRoot.appending(path: "nested", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
      var nestedEnvironment = environment
      nestedEnvironment[E2EEnvironmentKey.statusFIFO] =
        nested.appending(path: "status.fifo").path
      XCTAssertNil(E2EControl.load(environment: nestedEnvironment))

      let escapingLink = supportRoot.appending(
        path: "escaping-link",
        directoryHint: .isDirectory
      )
      try FileManager.default.createSymbolicLink(
        at: escapingLink,
        withDestinationURL: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
      )
      var invalidEnvironment = environment
      invalidEnvironment[E2EEnvironmentKey.statusFIFO] =
        escapingLink.appending(path: "status.fifo").path

      XCTAssertNil(E2EControl.load(environment: invalidEnvironment))
    }

    func testLoaderRejectsMissingRegularFileAndSymlinkSupportRoots() throws {
      let missing = uniqueSupportURL(label: "missing")
      XCTAssertNil(E2EControl.load(environment: environment(supportRoot: missing)))

      let regular = uniqueSupportURL(label: "regular")
      XCTAssertTrue(FileManager.default.createFile(atPath: regular.path, contents: Data()))
      cleanupURLs.append(regular)
      XCTAssertNil(E2EControl.load(environment: environment(supportRoot: regular)))

      let symlink = uniqueSupportURL(label: "symlink")
      try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: supportRoot)
      cleanupURLs.append(symlink)
      XCTAssertNil(E2EControl.load(environment: environment(supportRoot: symlink)))
    }

    func testLoaderRejectsWrongOwnerAndResolvedPathThroughInspectionSeam() {
      let validInspection = E2ESupportDirectoryInspection(
        isDirectory: true,
        isSymbolicLink: false,
        ownerUID: getuid(),
        resolvedPath: supportRoot.path
      )
      let wrongOwner = E2ESupportDirectoryInspection(
        isDirectory: true,
        isSymbolicLink: false,
        ownerUID: getuid() &+ 1,
        resolvedPath: supportRoot.path
      )
      let wrongResolution = E2ESupportDirectoryInspection(
        isDirectory: true,
        isSymbolicLink: false,
        ownerUID: getuid(),
        resolvedPath: "/private/tmp/pickvia-e2e-different-root"
      )

      XCTAssertNil(
        E2EControl.load(
          environment: environment,
          currentUID: getuid(),
          inspectSupportDirectory: { _ in wrongOwner }
        )
      )
      XCTAssertNil(
        E2EControl.load(
          environment: environment,
          currentUID: getuid(),
          inspectSupportDirectory: { _ in wrongResolution }
        )
      )
      XCTAssertEqual(
        E2EControl.load(
          environment: environment,
          currentUID: getuid(),
          inspectSupportDirectory: { _ in validInspection }
        ),
        expectedLoadedControl
      )
    }

    private func assertShapeMismatch(
      _ decision: E2ETargetDecision,
      file: StaticString = #filePath,
      line: UInt = #line
    ) {
      guard case .reject(let outcome) = decision else {
        return XCTFail(
          "Expected a closed target-shape rejection, got \(decision)", file: file, line: line)
      }
      XCTAssertEqual(outcome.rawValue, "target-shape-mismatch", file: file, line: line)
    }

    private var environment: [String: String] {
      environment(supportRoot: supportRoot)
    }

    private var expectedLoadedControl: E2EControl {
      E2EControl(
        targetID: Fixtures.control.targetID,
        expectedBundleIdentifier: Fixtures.control.expectedBundleIdentifier,
        expectedMode: Fixtures.control.expectedMode,
        sessionNonce: Fixtures.control.sessionNonce,
        applicationSupportDirectory: supportRoot,
        statusFIFO: supportRoot.appending(path: "status.fifo")
      )
    }

    private func environment(supportRoot: URL) -> [String: String] {
      [
        E2EEnvironmentKey.targetID: Fixtures.control.targetID,
        E2EEnvironmentKey.bundleIdentifier: Fixtures.control.expectedBundleIdentifier,
        E2EEnvironmentKey.mode: Fixtures.control.expectedMode.rawValue,
        E2EEnvironmentKey.sessionNonce: Fixtures.control.sessionNonce,
        E2EEnvironmentKey.supportDirectory: supportRoot.path,
        E2EEnvironmentKey.statusFIFO: supportRoot.appending(path: "status.fifo").path,
      ]
    }

    private func uniqueSupportURL(label: String) -> URL {
      URL(
        fileURLWithPath: "/private/tmp/pickvia-e2e-\(label)-\(UUID().uuidString)",
        isDirectory: true
      )
    }

    private func makeRealFirefoxProfileDirectory(label: String) throws -> URL {
      let profile =
        supportRoot
        .appending(path: "firefox-profile-\(label)", directoryHint: .isDirectory)
        .standardizedFileURL
      try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: false)
      return profile
    }
  }

  private enum Fixtures {
    static let edgeBundleIdentifier = "com.microsoft.edgemac"
    static let firefoxBundleIdentifier = "org.mozilla.firefox"
    static let operaBundleIdentifier = "com.operasoftware.Opera"
    static let unsupportedBundleIdentifier = "example.unsupported.browser"
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

    static func control(
      targetID: RouteTarget.ID,
      bundleIdentifier: String = edgeBundleIdentifier,
      mode: BrowserMode = .normal
    ) -> E2EControl {
      E2EControl(
        targetID: targetID,
        expectedBundleIdentifier: bundleIdentifier,
        expectedMode: mode,
        sessionNonce: control.sessionNonce,
        applicationSupportDirectory: control.applicationSupportDirectory,
        statusFIFO: control.statusFIFO
      )
    }

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
      family: .chromium,
      isAvailable: true
    )
    static let chrome = application(
      id: "com.google.Chrome",
      bundleIdentifier: "com.google.Chrome",
      family: .chromium,
      isAvailable: true
    )
    static let edgeWithWrongBundle = application(
      id: edgeBundleIdentifier,
      bundleIdentifier: "com.microsoft.edgemac.Beta",
      family: .chromium,
      isAvailable: true
    )
    static let unavailableEdgeApplication = application(
      id: edgeBundleIdentifier,
      bundleIdentifier: edgeBundleIdentifier,
      family: .chromium,
      isAvailable: false
    )
    static let edgeWithWrongFamily = application(
      id: edgeBundleIdentifier,
      bundleIdentifier: edgeBundleIdentifier,
      family: .firefox,
      isAvailable: true
    )
    static let firefox = application(
      id: firefoxBundleIdentifier,
      bundleIdentifier: firefoxBundleIdentifier,
      family: .firefox,
      isAvailable: true
    )
    static let opera = application(
      id: operaBundleIdentifier,
      bundleIdentifier: operaBundleIdentifier,
      family: .opera,
      isAvailable: true
    )
    static let unsupported = application(
      id: unsupportedBundleIdentifier,
      bundleIdentifier: unsupportedBundleIdentifier,
      family: .chromium,
      isAvailable: true
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
    static let edgeProfileFixture = profileFixture(
      application: edge,
      identity: "Profile 1",
      launchIdentifier: "Profile 1"
    )
    static func firefoxProfileFixture(
      profilePath: URL
    ) -> (control: E2EControl, application: RoutedApplication, target: RouteTarget) {
      let normalizedPath = profilePath.standardizedFileURL
      return profileFixture(
        application: firefox,
        identity: FirefoxProfileIdentity.identifier(for: normalizedPath),
        launchIdentifier: "Synthetic profile",
        profileLaunchPath: normalizedPath.path
      )
    }

    static func firefoxProfileTarget(
      id: RouteTarget.ID,
      identity: String,
      launchPath: String?
    ) -> RouteTarget {
      target(
        id: id,
        browserID: firefoxBundleIdentifier,
        profileIdentifier: "Synthetic profile",
        profileDisplayName: "Synthetic profile",
        profileIdentity: identity,
        profileLaunchPath: launchPath
      )
    }

    static func application(
      id: String,
      bundleIdentifier: String,
      family: BrowserFamily,
      isAvailable: Bool
    ) -> RoutedApplication {
      RoutedApplication(
        id: id,
        family: family,
        displayName: "Synthetic browser",
        bundleIdentifier: bundleIdentifier,
        applicationURL: URL(fileURLWithPath: "/Applications/Synthetic Browser.app"),
        executableURL: nil,
        isAvailable: isAvailable
      )
    }

    static func target(
      id: RouteTarget.ID? = nil,
      browserID: RoutedApplication.ID = edgeBundleIdentifier,
      mode: BrowserMode = .normal,
      isEnabled: Bool = true,
      availability: TargetAvailability = .available,
      origin: TargetOrigin = .detected,
      profileIdentifier: String? = nil,
      profileDisplayName: String? = nil,
      profileIdentity: String? = nil,
      profileLaunchPath: String? = nil
    ) -> RouteTarget {
      RouteTarget(
        id: id ?? control.targetID,
        browserID: browserID,
        label: "Synthetic target",
        profileIdentifier: profileIdentifier,
        profileDisplayName: profileDisplayName,
        profileIdentity: profileIdentity,
        profileLaunchPath: profileLaunchPath,
        mode: mode,
        isEnabled: isEnabled,
        sortOrder: 0,
        origin: origin,
        availability: availability
      )
    }

    private static func profileFixture(
      application: RoutedApplication,
      identity: String,
      launchIdentifier: String,
      profileLaunchPath: String? = nil
    ) -> (control: E2EControl, application: RoutedApplication, target: RouteTarget) {
      let targetID = BrowserCatalog.targetID(
        bundleIdentifier: application.bundleIdentifier,
        profileIdentifier: identity,
        mode: .normal
      )
      return (
        control: control(targetID: targetID, bundleIdentifier: application.bundleIdentifier),
        application: application,
        target: target(
          id: targetID,
          browserID: application.id,
          profileIdentifier: launchIdentifier,
          profileDisplayName: "Synthetic profile",
          profileIdentity: identity,
          profileLaunchPath: profileLaunchPath
        )
      )
    }
  }
#endif
