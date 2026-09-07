#if PICKVIA_E2E_AUTOMATION
  import Darwin
  import Foundation
  import PickViaCore
  import XCTest

  @testable import PickVia

  final class E2EProfileGrantTests: XCTestCase {
    private var supportRoot: URL!

    override func setUpWithError() throws {
      supportRoot = URL(
        fileURLWithPath: "/private/tmp/pickvia-e2e-profile-grant-\(UUID().uuidString)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: false)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: supportRoot.path
      )
    }

    override func tearDownWithError() throws {
      if let supportRoot, supportRoot.path.hasPrefix("/private/tmp/pickvia-e2e-profile-grant-") {
        try? FileManager.default.removeItem(at: supportRoot)
      }
      supportRoot = nil
    }

    func testInstallsPhysicalChromiumAndFirefoxRootsAndMakesThemImmediatelyVisible() throws {
      let fixtureMakers: [() throws -> ProfileGrantFixture] = [
        { try self.makeChromiumFixture() },
        { try self.makeFirefoxFixture() },
      ]
      for makeFixture in fixtureMakers {
        let fixture = try makeFixture()
        let coordinator = ProfileGrantCoordinatorSpy(
          persistence: .persistent,
          accessRoot: fixture.root
        )

        let validatedGrant = try E2EProfileGrantInstaller.installIfPresent(
          control: fixture.control,
          descriptors: [fixture.descriptor],
          coordinator: coordinator
        )

        XCTAssertEqual(validatedGrant?.descriptor, fixture.descriptor)
        XCTAssertEqual(validatedGrant?.root, fixture.root)
        let expectedProfileIdentifier =
          switch fixture.descriptor.profileStrategy {
          case .chromium: "Default"
          case .firefox: "synthetic0.default"
          case .none, .safariShortcut, .safariAccessibility: "unsupported"
          }
        XCTAssertEqual(
          validatedGrant?.profileIdentifier,
          expectedProfileIdentifier
        )
        XCTAssertEqual(
          coordinator.installations, [fixture.descriptor.bundleIdentifier: fixture.root])
        XCTAssertEqual(
          coordinator.beginAccessBundleIdentifiers, [fixture.descriptor.bundleIdentifier])
        XCTAssertEqual(coordinator.endedLeaseRoots, [fixture.root])
      }
    }

    func testCurrentSessionOnlyGrantIsAcceptedWhenImmediatelyVisible() throws {
      let fixture = try makeChromiumFixture()
      let coordinator = ProfileGrantCoordinatorSpy(
        persistence: .currentSessionOnly,
        accessRoot: fixture.root
      )

      _ = try E2EProfileGrantInstaller.installIfPresent(
        control: fixture.control,
        descriptors: [fixture.descriptor],
        coordinator: coordinator
      )

      XCTAssertEqual(coordinator.installations.count, 1)
      XCTAssertEqual(coordinator.beginAccessBundleIdentifiers.count, 1)
    }

    func testMissingManifestIsAnExplicitNoOp() throws {
      let coordinator = ProfileGrantCoordinatorSpy()

      let validatedGrant = try E2EProfileGrantInstaller.installIfPresent(
        control: control(bundleIdentifier: "com.microsoft.edgemac"),
        descriptors: [try descriptor(bundleIdentifier: "com.microsoft.edgemac")],
        coordinator: coordinator
      )

      XCTAssertNil(validatedGrant)
      XCTAssertTrue(coordinator.installations.isEmpty)
      XCTAssertTrue(coordinator.beginAccessBundleIdentifiers.isEmpty)
    }

    func testRejectsWrongBundleAndStrategy() throws {
      for mutation in [
        E2EProfileGrantManifest(
          schemaVersion: 1,
          bundleIdentifier: "com.google.Chrome",
          strategy: "chromium",
          relativeRoot: "profiles/chromium"
        ),
        E2EProfileGrantManifest(
          schemaVersion: 1,
          bundleIdentifier: "com.microsoft.edgemac",
          strategy: "firefox",
          relativeRoot: "profiles/chromium"
        ),
      ] {
        let fixture = try makeChromiumFixture(manifest: mutation)
        XCTAssertThrowsError(
          try E2EProfileGrantInstaller.installIfPresent(
            control: fixture.control,
            descriptors: [fixture.descriptor],
            coordinator: ProfileGrantCoordinatorSpy(accessRoot: fixture.root)
          )
        )
      }
    }

    func testRejectsUnsupportedSchemaMalformedAndNonClosedManifestJSON() throws {
      let fixture = try makeChromiumFixture()
      for data in [
        Data("not-json".utf8),
        Data(
          #"{"schemaVersion":2,"bundleIdentifier":"com.microsoft.edgemac","strategy":"chromium","relativeRoot":"profiles/chromium"}"#
            .utf8
        ),
        Data(
          #"{"schemaVersion":1,"bundleIdentifier":"com.microsoft.edgemac","strategy":"chromium","relativeRoot":"profiles/chromium","path":"/private/tmp/leak"}"#
            .utf8
        ),
      ] {
        try writeManifestData(data, control: fixture.control)
        XCTAssertThrowsError(
          try E2EProfileGrantInstaller.installIfPresent(
            control: fixture.control,
            descriptors: [fixture.descriptor],
            coordinator: ProfileGrantCoordinatorSpy(accessRoot: fixture.root)
          )
        )
      }
    }

    func testRejectsDuplicateManifestFieldsIncludingIdenticalAndConflictingValues() throws {
      let fixture = try makeChromiumFixture()
      let cases: [(String, String, String)] = [
        ("schemaVersion", "1", "2"),
        ("bundleIdentifier", #""com.microsoft.edgemac""#, #""com.google.Chrome""#),
        ("strategy", #""chromium""#, #""firefox""#),
        ("relativeRoot", #""profiles/chromium""#, #""profiles/other""#),
      ]
      for (field, identicalValue, conflictingValue) in cases {
        for duplicateValue in [identicalValue, conflictingValue] {
          let data = duplicateManifestData(
            duplicateField: field,
            duplicateValue: duplicateValue
          )
          try writeManifestData(data, control: fixture.control)
          XCTAssertThrowsError(
            try E2EProfileGrantInstaller.installIfPresent(
              control: fixture.control,
              descriptors: [fixture.descriptor],
              coordinator: ProfileGrantCoordinatorSpy(accessRoot: fixture.root)
            ),
            "duplicate \(field): \(duplicateValue)"
          )
        }
      }

      let escapedDuplicate = Data(
        #"{"schemaVersion":1,"\u0073chemaVersion":1,"bundleIdentifier":"com.microsoft.edgemac","strategy":"chromium","relativeRoot":"profiles/chromium"}"#
          .utf8
      )
      try writeManifestData(escapedDuplicate, control: fixture.control)
      XCTAssertThrowsError(
        try install(fixture, coordinator: ProfileGrantCoordinatorSpy(accessRoot: fixture.root))
      )
    }

    func testRejectsNonFinitePartialTrailingAndWrongTypedManifestValues() throws {
      let fixture = try makeChromiumFixture()
      let invalidDocuments = [
        #"{"schemaVersion":NaN,"bundleIdentifier":"com.microsoft.edgemac","strategy":"chromium","relativeRoot":"profiles/chromium"}"#,
        #"{"schemaVersion":Infinity,"bundleIdentifier":"com.microsoft.edgemac","strategy":"chromium","relativeRoot":"profiles/chromium"}"#,
        #"{"schemaVersion":1.0,"bundleIdentifier":"com.microsoft.edgemac","strategy":"chromium","relativeRoot":"profiles/chromium"}"#,
        #"{"schemaVersion":true,"bundleIdentifier":"com.microsoft.edgemac","strategy":"chromium","relativeRoot":"profiles/chromium"}"#,
        #"{"schemaVersion":1,"bundleIdentifier":1,"strategy":"chromium","relativeRoot":"profiles/chromium"}"#,
        #"{"schemaVersion":1,"bundleIdentifier":"com.microsoft.edgemac","strategy":null,"relativeRoot":"profiles/chromium"}"#,
        #"{"schemaVersion":1,"bundleIdentifier":"com.microsoft.edgemac","strategy":"chromium","relativeRoot":[]}"#,
        #"{"schemaVersion":1,"bundleIdentifier":"com.microsoft.edgemac","strategy":"chromium","relativeRoot":"profiles/chromium""#,
        #"{"schemaVersion":1,"bundleIdentifier":"com.microsoft.edgemac","strategy":"chromium","relativeRoot":"profiles/chromium"}{}"#,
      ]
      for document in invalidDocuments {
        try writeManifestData(Data(document.utf8), control: fixture.control)
        XCTAssertThrowsError(
          try install(fixture, coordinator: ProfileGrantCoordinatorSpy(accessRoot: fixture.root)),
          document
        )
      }
    }

    func testRejectsAbsoluteTraversalEmptyAndConventionalHomeRoots() throws {
      let fixture = try makeChromiumFixture()
      for relativeRoot in [
        "",
        ".",
        "../profiles/chromium",
        "profiles/../../escaped",
        "/private/tmp/pickvia-e2e-external",
        FileManager.default.homeDirectoryForCurrentUser.appending(
          path: "Library/Application Support/Microsoft Edge"
        ).path,
      ] {
        try writeManifest(
          E2EProfileGrantManifest(
            schemaVersion: 1,
            bundleIdentifier: fixture.descriptor.bundleIdentifier,
            strategy: "chromium",
            relativeRoot: relativeRoot
          ),
          control: fixture.control
        )
        XCTAssertThrowsError(
          try E2EProfileGrantInstaller.installIfPresent(
            control: fixture.control,
            descriptors: [fixture.descriptor],
            coordinator: ProfileGrantCoordinatorSpy(accessRoot: fixture.root)
          ),
          relativeRoot
        )
      }
    }

    func testRejectsSymlinkedRootPermissiveModeAndWrongOwner() throws {
      let fixture = try makeChromiumFixture()
      let physical = fixture.root
      let symlink = supportRoot.appending(path: "profiles/symlink", directoryHint: .isDirectory)
      try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: physical)
      try writeManifest(
        E2EProfileGrantManifest(
          schemaVersion: 1,
          bundleIdentifier: fixture.descriptor.bundleIdentifier,
          strategy: "chromium",
          relativeRoot: "profiles/symlink"
        ),
        control: fixture.control
      )
      XCTAssertThrowsError(
        try install(fixture, coordinator: ProfileGrantCoordinatorSpy(accessRoot: physical))
      )

      try writeManifest(fixture.manifest, control: fixture.control)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: physical.path)
      XCTAssertThrowsError(
        try install(fixture, coordinator: ProfileGrantCoordinatorSpy(accessRoot: physical))
      )

      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: physical.path)
      XCTAssertThrowsError(
        try E2EProfileGrantInstaller.installIfPresent(
          control: fixture.control,
          descriptors: [fixture.descriptor],
          coordinator: ProfileGrantCoordinatorSpy(accessRoot: physical),
          currentUID: getuid() &+ 1
        )
      )
    }

    func testRejectsMissingWrongAndSymlinkedMarker() throws {
      for mutation in ["missing", "wrong", "symlink"] {
        let fixture = try makeChromiumFixture()
        let marker = fixture.root.appending(path: "Local State")
        try FileManager.default.removeItem(at: marker)
        switch mutation {
        case "wrong":
          try writeRestricted(Data("{}".utf8), to: fixture.root.appending(path: "profiles.ini"))
        case "symlink":
          let external = supportRoot.appending(path: "external-marker-\(UUID().uuidString)")
          try writeRestricted(
            Data(chromiumLocalState(profileIdentifiers: ["Default"]).utf8), to: external)
          try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: external)
        default:
          break
        }
        XCTAssertThrowsError(
          try install(fixture, coordinator: ProfileGrantCoordinatorSpy(accessRoot: fixture.root)),
          mutation
        )
      }
    }

    func testRejectsZeroOrTwoProfilesForChromiumAndFirefox() throws {
      for count in [0, 2] {
        let chromium = try makeChromiumFixture(profileCount: count)
        XCTAssertThrowsError(
          try install(chromium, coordinator: ProfileGrantCoordinatorSpy(accessRoot: chromium.root))
        )

        let firefox = try makeFirefoxFixture(profileCount: count)
        XCTAssertThrowsError(
          try install(firefox, coordinator: ProfileGrantCoordinatorSpy(accessRoot: firefox.root))
        )
      }
    }

    func testRejectsExtraMalformedRawChromiumInfoCacheEntry() throws {
      let fixture = try makeChromiumFixture()
      let malformedEntries = [
        #"{}"#,
        #"{"name":""}"#,
        #""malformed""#,
      ]
      for malformedEntry in malformedEntries {
        let marker = Data(
          """
          {"profile":{"info_cache":{"Default":{"name":"PickVia E2E"},"Malformed":\(malformedEntry)}}}
          """.utf8
        )
        try replaceRestricted(marker, at: fixture.root.appending(path: "Local State"))
        XCTAssertThrowsError(
          try install(fixture, coordinator: ProfileGrantCoordinatorSpy(accessRoot: fixture.root)),
          malformedEntry
        )
      }
    }

    func testRejectsWrongSyntheticProfileNameAndEscapingFirefoxProfile() throws {
      let chromium = try makeChromiumFixture(displayName: "Personal")
      XCTAssertThrowsError(
        try install(chromium, coordinator: ProfileGrantCoordinatorSpy(accessRoot: chromium.root))
      )

      let firefox = try makeFirefoxFixture(firefoxPath: "../escaped.default")
      XCTAssertThrowsError(
        try install(firefox, coordinator: ProfileGrantCoordinatorSpy(accessRoot: firefox.root))
      )

      let normalizedTraversal = try makeFirefoxFixture(
        firefoxPath: "nested/../synthetic0.default"
      )
      try makeRestrictedDirectory(
        normalizedTraversal.root.appending(
          path: "synthetic0.default",
          directoryHint: .isDirectory
        )
      )
      XCTAssertThrowsError(
        try install(
          normalizedTraversal,
          coordinator: ProfileGrantCoordinatorSpy(accessRoot: normalizedTraversal.root)
        )
      )
    }

    func testRejectsStaleRevokedMissingAndWrongRootAccessAfterInstall() throws {
      let fixture = try makeChromiumFixture()
      let otherRoot = supportRoot.appending(path: "profiles/other", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: false)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: otherRoot.path)

      for coordinator in [
        ProfileGrantCoordinatorSpy(accessState: .revoked),
        ProfileGrantCoordinatorSpy(accessState: .missing),
        ProfileGrantCoordinatorSpy(accessRoot: otherRoot),
      ] {
        XCTAssertThrowsError(try install(fixture, coordinator: coordinator))
      }
    }

    func testRejectsRealCoordinatorAccessThatRefreshedAStaleBookmark() throws {
      let fixture = try makeChromiumFixture()
      let store = StaleProfileGrantStore()
      let codec = StaleProfileGrantBookmarkCodec(root: fixture.root)
      let resourceAccess = StaleProfileGrantResourceAccess()
      let coordinator = ProfileAccessCoordinator(
        store: store,
        bookmarkCodec: codec,
        resourceAccess: resourceAccess
      )

      XCTAssertThrowsError(
        try E2EProfileGrantInstaller.installIfPresent(
          control: fixture.control,
          descriptors: [fixture.descriptor],
          coordinator: coordinator
        )
      )
      XCTAssertEqual(codec.makeBookmarkCallCount, 2)
      XCTAssertEqual(codec.resolveCallCount, 1)
      XCTAssertEqual(store.savedBookmarks.count, 2)
      XCTAssertEqual(resourceAccess.startedRoots, [fixture.root])
      XCTAssertEqual(resourceAccess.stoppedRoots, [fixture.root])
    }

    func testRejectsManifestSymlinkAndPermissiveManifestMode() throws {
      let fixture = try makeChromiumFixture()
      let manifest = fixture.control.profileGrantManifest
      let external = supportRoot.appending(path: "external-manifest")
      try FileManager.default.moveItem(at: manifest, to: external)
      try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: external)
      XCTAssertThrowsError(
        try install(fixture, coordinator: ProfileGrantCoordinatorSpy(accessRoot: fixture.root))
      )

      try FileManager.default.removeItem(at: manifest)
      try FileManager.default.moveItem(at: external, to: manifest)
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest.path)
      XCTAssertThrowsError(
        try install(fixture, coordinator: ProfileGrantCoordinatorSpy(accessRoot: fixture.root))
      )
    }

    func testValidatedTaskOwnedChromiumGrantSelectsActualCatalogTarget() throws {
      let fixture = try makeGrantedChromiumSelectionFixture()

      XCTAssertEqual(fixture.target.profileIdentifier, "Profile 1")
      XCTAssertEqual(fixture.target.profileIdentity, "Profile 1")
      XCTAssertEqual(fixture.target.profileLaunchPath, fixture.profile.path)
      XCTAssertEqual(
        E2ETargetDecision.evaluate(
          control: fixture.control,
          requestKind: .web,
          applications: [fixture.application],
          targets: [fixture.target],
          descriptors: [fixture.descriptor],
          profileGrant: fixture.grant
        ),
        .select(fixture.target.id)
      )

      let launchPlan = try BrowserLauncher(
        trustedApplicationResolver: ProfileGrantApplicationLocator(
          bundleIdentifier: fixture.descriptor.bundleIdentifier,
          applicationURL: fixture.application.applicationURL
        ),
        executableValidator: ProfileGrantExecutableValidator()
      ).makePlan(
        url: URL(string: "https://example.invalid/e2e-grant")!,
        application: fixture.application,
        target: fixture.target
      )
      guard case .profileExecutable(_, let arguments, _) = launchPlan else {
        return XCTFail("Expected the granted profile to produce a pinned executable plan")
      }
      XCTAssertEqual(
        arguments.prefix(2),
        ["--user-data-dir=\(fixture.root.path)", "--profile-directory=Profile 1"]
      )
    }

    func testValidatedGrantSurvivesOrdinaryTaskSupportStateWrites() throws {
      let fixture = try makeGrantedChromiumSelectionFixture(rootName: "support-state")
      try writeRestricted(
        Data("task-local-state".utf8),
        to: supportRoot.appending(path: "config.json")
      )

      XCTAssertEqual(
        E2ETargetDecision.evaluate(
          control: fixture.control,
          requestKind: .web,
          applications: [fixture.application],
          targets: [fixture.target],
          descriptors: [fixture.descriptor],
          profileGrant: fixture.grant
        ),
        .select(fixture.target.id)
      )
    }

    func testChromiumLaunchPathRejectsMissingGrantAndEveryUnboundPathShape() throws {
      let fixture = try makeGrantedChromiumSelectionFixture()
      assertShapeMismatch(fixture, target: fixture.target, includeProfileGrant: false)

      let outsideRoot = supportRoot.appending(
        path: "outside/Profile 1",
        directoryHint: .isDirectory
      )
      try makeRestrictedDirectory(outsideRoot)
      assertShapeMismatch(
        fixture,
        target: copy(fixture.target, profileLaunchPath: outsideRoot.path)
      )
      assertShapeMismatch(
        fixture,
        target: copy(fixture.target, profileLaunchPath: "profiles/chromium/Profile 1")
      )

      let mismatchedIdentifier = "Profile 9"
      let mismatchedID = BrowserCatalog.targetID(
        bundleIdentifier: fixture.descriptor.bundleIdentifier,
        profileIdentifier: mismatchedIdentifier,
        mode: .normal
      )
      assertShapeMismatch(
        fixture,
        control: copy(fixture.control, targetID: mismatchedID),
        target: copy(
          fixture.target,
          id: mismatchedID,
          profileIdentifier: mismatchedIdentifier,
          profileIdentity: mismatchedIdentifier,
          profileLaunchPath: fixture.target.profileLaunchPath!
        )
      )

      let forgedDescriptor = BrowserDescriptor(
        bundleIdentifier: fixture.descriptor.bundleIdentifier,
        family: fixture.descriptor.family,
        displayName: fixture.descriptor.displayName,
        profileStrategy: .chromium(root: "Forged E2E Root"),
        launchStrategy: fixture.descriptor.launchStrategy,
        privateStrategy: fixture.descriptor.privateStrategy,
        routeCapabilityPolicy: fixture.descriptor.routeCapabilityPolicy
      )
      assertShapeMismatch(
        fixture,
        target: fixture.target,
        descriptors: [forgedDescriptor]
      )
    }

    func testChromiumGrantRejectsSymlinkedAncestorRootAndProfile() throws {
      do {
        let fixture = try makeGrantedChromiumSelectionFixture(rootName: "ancestor/chromium")
        let ancestor = fixture.root.deletingLastPathComponent()
        let physical = supportRoot.appending(
          path: "physical-ancestor",
          directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(at: ancestor, to: physical)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: physical)
        assertShapeMismatch(fixture, target: fixture.target)
      }

      do {
        let fixture = try makeGrantedChromiumSelectionFixture(rootName: "root-link")
        let physical = supportRoot.appending(
          path: "physical-root",
          directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(at: fixture.root, to: physical)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: physical)
        assertShapeMismatch(fixture, target: fixture.target)
      }

      do {
        let fixture = try makeGrantedChromiumSelectionFixture(rootName: "profile-link")
        let physical = fixture.root.appending(
          path: "Default-physical",
          directoryHint: .isDirectory
        )
        try FileManager.default.moveItem(at: fixture.profile, to: physical)
        try FileManager.default.createSymbolicLink(
          at: fixture.profile,
          withDestinationURL: physical
        )
        assertShapeMismatch(fixture, target: fixture.target)
      }
    }

    func testChromiumGrantRejectsReplacedGenerationAndChangedMode() throws {
      do {
        let fixture = try makeGrantedChromiumSelectionFixture(rootName: "replaced")
        try FileManager.default.removeItem(at: fixture.profile)
        try makeRestrictedDirectory(fixture.profile)
        assertShapeMismatch(fixture, target: fixture.target)
      }

      do {
        let fixture = try makeGrantedChromiumSelectionFixture(rootName: "mode")
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o755],
          ofItemAtPath: fixture.profile.path
        )
        assertShapeMismatch(fixture, target: fixture.target)
      }
    }

    private func install(
      _ fixture: ProfileGrantFixture,
      coordinator: ProfileGrantCoordinatorSpy
    ) throws {
      _ = try E2EProfileGrantInstaller.installIfPresent(
        control: fixture.control,
        descriptors: [fixture.descriptor],
        coordinator: coordinator
      )
    }

    private func makeChromiumFixture(
      profileCount: Int = 1,
      displayName: String = "PickVia E2E",
      profileIdentifier: String = "Default",
      rootName: String = "chromium",
      manifest suppliedManifest: E2EProfileGrantManifest? = nil
    ) throws -> ProfileGrantFixture {
      let descriptor = try descriptor(bundleIdentifier: "com.microsoft.edgemac")
      let control = control(bundleIdentifier: descriptor.bundleIdentifier)
      let relativeRoot = "profiles/\(rootName)"
      let root = supportRoot.appending(path: relativeRoot, directoryHint: .isDirectory)
      if FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
      }
      try makeRestrictedDirectory(root)
      let identifiers = (0..<profileCount).map {
        $0 == 0 ? profileIdentifier : "Profile \($0 + 1)"
      }
      for identifier in identifiers {
        try makeRestrictedDirectory(root.appending(path: identifier, directoryHint: .isDirectory))
      }
      try writeRestricted(
        Data(chromiumLocalState(profileIdentifiers: identifiers, displayName: displayName).utf8),
        to: root.appending(path: "Local State")
      )
      let manifest =
        suppliedManifest
        ?? E2EProfileGrantManifest(
          schemaVersion: 1,
          bundleIdentifier: descriptor.bundleIdentifier,
          strategy: "chromium",
          relativeRoot: relativeRoot
        )
      try writeManifest(manifest, control: control)
      return ProfileGrantFixture(
        control: control,
        descriptor: descriptor,
        root: root,
        manifest: manifest
      )
    }

    private func makeGrantedChromiumSelectionFixture(
      rootName: String = "chromium-selection"
    ) throws -> GrantedChromiumSelectionFixture {
      let fixture = try makeChromiumFixture(
        profileIdentifier: "Profile 1",
        rootName: rootName
      )
      let coordinator = ProfileGrantCoordinatorSpy(
        persistence: .currentSessionOnly,
        accessRoot: fixture.root
      )
      let grant = try XCTUnwrap(
        E2EProfileGrantInstaller.installIfPresent(
          control: fixture.control,
          descriptors: [fixture.descriptor],
          coordinator: coordinator
        )
      )
      let applicationURL = URL(
        fileURLWithPath: "/Applications/Synthetic Edge.app",
        isDirectory: true
      )
      let catalog = BrowserCatalog(
        descriptors: [fixture.descriptor],
        applicationLocator: ProfileGrantApplicationLocator(
          bundleIdentifier: fixture.descriptor.bundleIdentifier,
          applicationURL: applicationURL
        ),
        profileRootAccess: coordinator,
        preservesGrantedChromiumProfileRootPath: true,
        homeDirectory: supportRoot
      )
      let scan = catalog.scanResult()
      let browser = try XCTUnwrap(scan.browsers.first)
      let config = catalog.reconcile(discovered: scan.browsers, with: .initial)
      let target = try XCTUnwrap(
        config.targets.first {
          $0.profileIdentifier == "Profile 1"
            && $0.profileLaunchPath == fixture.root.appending(path: "Profile 1").path
            && $0.mode == .normal
        },
        "status=\(browser.metadataStatus) profiles=\(browser.profiles) targets=\(config.targets)"
      )
      return GrantedChromiumSelectionFixture(
        control: copy(fixture.control, targetID: target.id),
        descriptor: fixture.descriptor,
        application: browser.application,
        target: target,
        grant: grant,
        root: fixture.root,
        profile: fixture.root.appending(path: "Profile 1", directoryHint: .isDirectory)
      )
    }

    private func assertShapeMismatch(
      _ fixture: GrantedChromiumSelectionFixture,
      control: E2EControl? = nil,
      target: RouteTarget,
      descriptors: [BrowserDescriptor]? = nil,
      includeProfileGrant: Bool = true,
      file: StaticString = #filePath,
      line: UInt = #line
    ) {
      XCTAssertEqual(
        E2ETargetDecision.evaluate(
          control: control ?? fixture.control,
          requestKind: .web,
          applications: [fixture.application],
          targets: [target],
          descriptors: descriptors ?? [fixture.descriptor],
          profileGrant: includeProfileGrant ? fixture.grant : nil
        ),
        .reject(.targetShapeMismatch),
        file: file,
        line: line
      )
    }

    private func copy(_ control: E2EControl, targetID: RouteTarget.ID) -> E2EControl {
      E2EControl(
        targetID: targetID,
        expectedBundleIdentifier: control.expectedBundleIdentifier,
        expectedMode: control.expectedMode,
        sessionNonce: control.sessionNonce,
        requestNonce: control.requestNonce,
        applicationSupportDirectory: control.applicationSupportDirectory,
        statusFIFO: control.statusFIFO,
        provenanceFIFO: control.provenanceFIFO
      )
    }

    private func copy(
      _ target: RouteTarget,
      id: RouteTarget.ID? = nil,
      profileIdentifier: String? = nil,
      profileIdentity: String? = nil,
      profileLaunchPath: String
    ) -> RouteTarget {
      RouteTarget(
        id: id ?? target.id,
        browserID: target.browserID,
        label: target.label,
        profileIdentifier: profileIdentifier ?? target.profileIdentifier,
        profileDisplayName: target.profileDisplayName,
        profileIdentity: profileIdentity ?? target.profileIdentity,
        profileLaunchPath: profileLaunchPath,
        mode: target.mode,
        isEnabled: target.isEnabled,
        sortOrder: target.sortOrder,
        origin: target.origin,
        availability: target.availability,
        pendingDefaultMigration: target.pendingDefaultMigration,
        validationError: target.validationError
      )
    }

    private func makeFirefoxFixture(
      profileCount: Int = 1,
      firefoxPath: String? = nil
    ) throws -> ProfileGrantFixture {
      let descriptor = try descriptor(bundleIdentifier: "org.mozilla.firefox")
      let control = control(bundleIdentifier: descriptor.bundleIdentifier)
      let relativeRoot = "profiles/firefox"
      let root = supportRoot.appending(path: relativeRoot, directoryHint: .isDirectory)
      if FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
      }
      try makeRestrictedDirectory(root)
      var sections: [String] = []
      for index in 0..<profileCount {
        let path = firefoxPath ?? "synthetic\(index).default"
        if !path.contains("..") {
          try makeRestrictedDirectory(root.appending(path: path, directoryHint: .isDirectory))
        }
        sections.append(
          "[Profile\(index)]\nName=PickVia E2E\nIsRelative=1\nPath=\(path)\nDefault=1\n"
        )
      }
      try writeRestricted(
        Data(sections.joined(separator: "\n").utf8),
        to: root.appending(path: "profiles.ini")
      )
      let manifest = E2EProfileGrantManifest(
        schemaVersion: 1,
        bundleIdentifier: descriptor.bundleIdentifier,
        strategy: "firefox",
        relativeRoot: relativeRoot
      )
      try writeManifest(manifest, control: control)
      return ProfileGrantFixture(
        control: control,
        descriptor: descriptor,
        root: root,
        manifest: manifest
      )
    }

    private func control(bundleIdentifier: String) -> E2EControl {
      E2EControl(
        targetID: "\(bundleIdentifier)||normal",
        expectedBundleIdentifier: bundleIdentifier,
        expectedMode: .normal,
        sessionNonce: "session_0123456789",
        requestNonce: "request_0123456789",
        applicationSupportDirectory: supportRoot,
        statusFIFO: supportRoot.appending(path: "status.fifo"),
        provenanceFIFO: supportRoot.appending(path: "provenance.fifo")
      )
    }

    private func descriptor(bundleIdentifier: String) throws -> BrowserDescriptor {
      try XCTUnwrap(
        BrowserDescriptor.supported.first { $0.bundleIdentifier == bundleIdentifier }
      )
    }

    private func writeManifest(
      _ manifest: E2EProfileGrantManifest,
      control: E2EControl
    ) throws {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try writeManifestData(encoder.encode(manifest), control: control)
    }

    private func writeManifestData(_ data: Data, control: E2EControl) throws {
      if FileManager.default.fileExists(atPath: control.profileGrantManifest.path) {
        try FileManager.default.removeItem(at: control.profileGrantManifest)
      }
      try writeRestricted(data, to: control.profileGrantManifest)
    }

    private func duplicateManifestData(
      duplicateField: String,
      duplicateValue: String
    ) -> Data {
      let fields = [
        #""schemaVersion":1"#,
        #""bundleIdentifier":"com.microsoft.edgemac""#,
        #""strategy":"chromium""#,
        #""relativeRoot":"profiles/chromium""#,
        "\"\(duplicateField)\":\(duplicateValue)",
      ]
      return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    private func makeRestrictedDirectory(_ url: URL) throws {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeRestricted(_ data: Data, to url: URL) throws {
      XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: data))
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func replaceRestricted(_ data: Data, at url: URL) throws {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      try writeRestricted(data, to: url)
    }

    private func chromiumLocalState(
      profileIdentifiers: [String],
      displayName: String = "PickVia E2E"
    ) -> String {
      let cache = Dictionary(
        uniqueKeysWithValues: profileIdentifiers.map { identifier in
          (identifier, ["name": displayName])
        })
      let data = try! JSONSerialization.data(
        withJSONObject: ["profile": ["info_cache": cache]],
        options: [.sortedKeys]
      )
      return String(decoding: data, as: UTF8.self)
    }
  }

  private struct ProfileGrantFixture {
    let control: E2EControl
    let descriptor: BrowserDescriptor
    let root: URL
    let manifest: E2EProfileGrantManifest
  }

  private struct GrantedChromiumSelectionFixture {
    let control: E2EControl
    let descriptor: BrowserDescriptor
    let application: RoutedApplication
    let target: RouteTarget
    let grant: E2EValidatedProfileGrant
    let root: URL
    let profile: URL
  }

  private struct ProfileGrantApplicationLocator: ApplicationLocating,
    TrustedApplicationResolving
  {
    let bundleIdentifier: String
    let applicationURL: URL

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
      bundleIdentifier == self.bundleIdentifier ? applicationURL : nil
    }
  }

  private struct ProfileGrantExecutableValidator: ExecutableValidating {
    func isExecutableFile(at url: URL) -> Bool { true }
  }

  private final class ProfileGrantCoordinatorSpy: ProfileAccessManaging, @unchecked Sendable {
    private let persistence: ProfileGrantPersistence
    private let accessState: ProfileRootAccessState
    private let accessRoot: URL?
    private(set) var installations: [String: URL] = [:]
    private(set) var beginAccessBundleIdentifiers: [String] = []
    private(set) var endedLeaseRoots: [URL] = []

    init(
      persistence: ProfileGrantPersistence = .persistent,
      accessState: ProfileRootAccessState = .granted,
      accessRoot: URL? = nil
    ) {
      self.persistence = persistence
      self.accessState = accessState
      self.accessRoot = accessRoot
    }

    func beginAccess(for bundleIdentifier: String) -> ProfileRootAccessResult {
      beginAccessBundleIdentifiers.append(bundleIdentifier)
      guard accessState == .granted, let accessRoot else {
        return ProfileRootAccessResult(state: accessState, lease: nil)
      }
      return ProfileRootAccessResult(
        state: .granted,
        lease: ProfileRootLease(root: accessRoot) { [weak self] in
          self?.endedLeaseRoots.append(accessRoot)
        },
        provenance: persistence == .persistent ? .persistentBookmark : .currentSessionGrant
      )
    }

    func installGrant(
      root: URL,
      for bundleIdentifier: String
    ) throws -> ProfileGrantPersistence {
      installations[bundleIdentifier] = root
      return persistence
    }

    func persistence(for bundleIdentifier: String) -> ProfileGrantPersistence? {
      persistence
    }

    func removeGrant(for bundleIdentifier: String) throws {}
  }

  private final class StaleProfileGrantStore: ProfileAccessStoring, @unchecked Sendable {
    private var bookmark: Data?
    private(set) var savedBookmarks: [Data] = []

    func bookmark(for bundleIdentifier: String) throws -> Data? {
      bookmark
    }

    func save(_ bookmark: Data, for bundleIdentifier: String) throws {
      self.bookmark = bookmark
      savedBookmarks.append(bookmark)
    }

    func remove(for bundleIdentifier: String) throws {
      bookmark = nil
    }
  }

  private final class StaleProfileGrantBookmarkCodec: ProfileBookmarkCoding, @unchecked Sendable {
    private let root: URL
    private(set) var makeBookmarkCallCount = 0
    private(set) var resolveCallCount = 0

    init(root: URL) {
      self.root = root
    }

    func makeReadOnlyBookmark(for root: URL) throws -> Data {
      makeBookmarkCallCount += 1
      return Data("bookmark-\(makeBookmarkCallCount)".utf8)
    }

    func resolve(_ bookmark: Data) throws -> ResolvedProfileBookmark {
      resolveCallCount += 1
      return ResolvedProfileBookmark(root: root, isStale: true)
    }
  }

  private final class StaleProfileGrantResourceAccess: SecurityScopedResourceAccessing,
    @unchecked Sendable
  {
    private(set) var startedRoots: [URL] = []
    private(set) var stoppedRoots: [URL] = []

    func startAccessing(_ url: URL) -> Bool {
      startedRoots.append(url)
      return true
    }

    func stopAccessing(_ url: URL) {
      stoppedRoots.append(url)
    }
  }
#endif
