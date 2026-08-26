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

        try E2EProfileGrantInstaller.installIfPresent(
          control: fixture.control,
          descriptors: [fixture.descriptor],
          coordinator: coordinator
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

      try E2EProfileGrantInstaller.installIfPresent(
        control: fixture.control,
        descriptors: [fixture.descriptor],
        coordinator: coordinator
      )

      XCTAssertEqual(coordinator.installations.count, 1)
      XCTAssertEqual(coordinator.beginAccessBundleIdentifiers.count, 1)
    }

    func testMissingManifestIsAnExplicitNoOp() throws {
      let coordinator = ProfileGrantCoordinatorSpy()

      try E2EProfileGrantInstaller.installIfPresent(
        control: control(bundleIdentifier: "com.microsoft.edgemac"),
        descriptors: [try descriptor(bundleIdentifier: "com.microsoft.edgemac")],
        coordinator: coordinator
      )

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

    private func install(
      _ fixture: ProfileGrantFixture,
      coordinator: ProfileGrantCoordinatorSpy
    ) throws {
      try E2EProfileGrantInstaller.installIfPresent(
        control: fixture.control,
        descriptors: [fixture.descriptor],
        coordinator: coordinator
      )
    }

    private func makeChromiumFixture(
      profileCount: Int = 1,
      displayName: String = "PickVia E2E",
      manifest suppliedManifest: E2EProfileGrantManifest? = nil
    ) throws -> ProfileGrantFixture {
      let descriptor = try descriptor(bundleIdentifier: "com.microsoft.edgemac")
      let control = control(bundleIdentifier: descriptor.bundleIdentifier)
      let relativeRoot = "profiles/chromium"
      let root = supportRoot.appending(path: relativeRoot, directoryHint: .isDirectory)
      if FileManager.default.fileExists(atPath: root.path) {
        try FileManager.default.removeItem(at: root)
      }
      try makeRestrictedDirectory(root)
      let identifiers = (0..<profileCount).map { $0 == 0 ? "Default" : "Profile \($0)" }
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

    private func makeRestrictedDirectory(_ url: URL) throws {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func writeRestricted(_ data: Data, to url: URL) throws {
      XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: data))
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
        }
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
#endif
