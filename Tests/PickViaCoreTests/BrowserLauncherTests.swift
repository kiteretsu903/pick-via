import Foundation
import Testing

@testable import PickViaCore

struct BrowserLauncherTests {
  private let url = URL(string: "https://example.com")!

  @Test func mailTargetIsRejectedWithoutReadingBrowserOptions() {
    let application = RoutedApplication(
      id: "com.google.Chrome",
      displayName: "Google Chrome",
      bundleIdentifier: "com.google.Chrome",
      capabilities: [
        .browser(family: .chromium, isAvailable: true),
        .mail(isAvailable: true),
      ],
      applicationURL: applicationURL
    )
    let mailTarget = RouteTarget(
      id: RouteTarget.mailID(bundleIdentifier: application.bundleIdentifier),
      applicationID: application.id,
      label: "Google Chrome Mail",
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available,
      capability: .mail
    )

    #expect(throws: LaunchFailure.self) {
      try testLauncher().makePlan(
        url: url,
        application: application,
        target: mailTarget
      )
    }
  }

  @Test func chromiumNormalPlanUsesExactProfileAndURLTokens() throws {
    let launcher = testLauncher()

    let plan = try launcher.makePlan(
      url: URL(string: "https://example.com/a?x=1")!,
      application: application(family: .chromium),
      target: target(family: .chromium, profile: "Profile 1")
    )

    guard case .executable(let application, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(application == applicationURL.appending(path: "Contents/MacOS/Google Chrome"))
    #expect(arguments == ["--profile-directory=Profile 1", "https://example.com/a?x=1"])
  }

  @Test func persistedApplicationAndExecutablePathsAreIgnoredAtLaunchBoundary() throws {
    let trustedApplication = URL(
      fileURLWithPath: "/Applications/Trusted Google Chrome.app", isDirectory: true)
    let substituted = BrowserApplication(
      id: "com.google.Chrome",
      family: .chromium,
      displayName: "Google Chrome",
      bundleIdentifier: "com.google.Chrome",
      applicationURL: URL(fileURLWithPath: "/tmp/Evil.app", isDirectory: true),
      executableURL: URL(fileURLWithPath: "/tmp/payload"),
      isAvailable: true
    )
    let launcher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
        "com.google.Chrome": trustedApplication
      ]),
      processRunner: RecordingProcessRunner(),
      workspace: RecordingWorkspace(),
      executableValidator: StubExecutableValidator(isExecutable: true)
    )

    let plan = try launcher.makePlan(
      url: url,
      application: substituted,
      target: target(family: .chromium, profile: nil)
    )

    guard case .executable(let executable, _) = plan else {
      Issue.record("Expected executable plan")
      return
    }
    #expect(
      executable
        == trustedApplication.appending(path: "Contents/MacOS/Google Chrome"))
    #expect(!executable.path.hasPrefix("/tmp"))
  }

  @Test func chromeBetaUsesTrustedBetaExecutableAndChromiumArguments() throws {
    let betaApplication = BrowserApplication(
      id: "com.google.Chrome.beta",
      family: .chromium,
      displayName: "Google Chrome Beta",
      bundleIdentifier: "com.google.Chrome.beta",
      applicationURL: URL(fileURLWithPath: "/tmp/Evil Beta.app", isDirectory: true),
      executableURL: URL(fileURLWithPath: "/tmp/beta-payload"),
      isAvailable: true
    )
    let trustedBetaApplication = URL(
      fileURLWithPath: "/Applications/Google Chrome Beta.app", isDirectory: true)
    let launcher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
        "com.google.Chrome.beta": trustedBetaApplication
      ]),
      processRunner: RecordingProcessRunner(),
      workspace: RecordingWorkspace(),
      executableValidator: StubExecutableValidator(isExecutable: true)
    )
    let betaTarget = target(
      id: BrowserCatalog.targetID(
        bundleIdentifier: "com.google.Chrome.beta",
        profileIdentifier: "Profile 1",
        mode: .private
      ),
      browserID: "com.google.Chrome.beta",
      profile: "Profile 1",
      mode: .private
    )

    let plan = try launcher.makePlan(url: url, application: betaApplication, target: betaTarget)

    guard case .executable(let executable, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(
      executable
        == URL(
          fileURLWithPath: "/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta")
    )
    #expect(arguments == ["--profile-directory=Profile 1", "--incognito", "https://example.com"])
  }

  @Test func launchFailsWhenSupportedBundleCannotBeResolvedCurrently() {
    let launcher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [:]),
      processRunner: RecordingProcessRunner(),
      workspace: RecordingWorkspace(),
      executableValidator: StubExecutableValidator(isExecutable: true)
    )

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: application(family: .chromium),
        target: target(family: .chromium, profile: nil)
      )
    }
  }

  @Test func duckDuckGoPlansPreserveNormalAndFireModes() throws {
    let launcher = duckDuckGoLauncher(router: RecordingDuckDuckGoRouter())

    for mode in [BrowserMode.normal, .private] {
      let plan = try launcher.makePlan(
        url: url,
        application: application(family: .duckDuckGo, executable: nil),
        target: duckDuckGoTarget(mode: mode)
      )

      #expect(
        plan
          == .duckDuckGo(
            application: applicationURL,
            url: url,
            mode: mode
          )
      )
    }
  }

  @Test(arguments: DuckDuckGoProfileField.allCases)
  func duckDuckGoRejectsEveryProfileBearingTarget(field: DuckDuckGoProfileField) {
    #expect(throws: LaunchFailure.self) {
      try duckDuckGoLauncher(router: RecordingDuckDuckGoRouter()).makePlan(
        url: url,
        application: application(family: .duckDuckGo, executable: nil),
        target: duckDuckGoTarget(profileField: field)
      )
    }
  }

  @Test func executeForwardsDuckDuckGoPlanToInjectedRouter() async throws {
    let router = RecordingDuckDuckGoRouter()
    let launcher = duckDuckGoLauncher(router: router)

    try await launcher.execute(
      .duckDuckGo(
        application: applicationURL,
        url: url,
        mode: .private
      )
    )

    #expect(
      await router.invocations == [
        .init(
          url: url,
          applicationURL: applicationURL,
          mode: .private
        )
      ]
    )
  }

  @Test func duckDuckGoRouterErrorBecomesSafeLaunchFailure() async {
    let launcher = duckDuckGoLauncher(
      router: RecordingDuckDuckGoRouter(errorCode: -1)
    )

    do {
      try await launcher.execute(
        .duckDuckGo(
          application: applicationURL,
          url: url,
          mode: .private
        )
      )
      Issue.record("Expected execution failure")
    } catch let failure as LaunchFailure {
      #expect(failure.message == "Could not open the selected browser target.")
      #expect(!failure.message.contains(url.absoluteString))
    } catch {
      Issue.record("Expected LaunchFailure, got \(type(of: error))")
    }
  }

  @Test func unprofiledChromiumAndFirefoxPlansUseBrowserLevelArguments() throws {
    let launcher = testLauncher()

    func arguments(for family: BrowserFamily, mode: BrowserMode) throws -> [String] {
      let plan = try launcher.makePlan(
        url: url,
        application: application(family: family),
        target: target(
          id: BrowserCatalog.targetID(
            bundleIdentifier: bundleID(for: family),
            profileIdentifier: nil,
            mode: mode
          ),
          family: family,
          profile: nil,
          mode: mode
        )
      )
      guard case .executable(_, let arguments) = plan else {
        Issue.record("Expected executable plan")
        return []
      }
      return arguments
    }

    #expect(try arguments(for: .chromium, mode: .normal) == [url.absoluteString])
    #expect(
      try arguments(for: .chromium, mode: .private) == ["--incognito", url.absoluteString])
    #expect(try arguments(for: .firefox, mode: .normal) == ["-new-tab", url.absoluteString])
    #expect(
      try arguments(for: .firefox, mode: .private) == ["-private-window", url.absoluteString])
  }

  @Test func unprofiledManualFirefoxUUIDTargetRemainsBrowserLevelRoutable() throws {
    let plan = try testLauncher().makePlan(
      url: url,
      application: application(family: .firefox),
      target: target(
        id: "774bb7ed-d61c-4be7-89f1-6c16daf287be",
        family: .firefox,
        profile: nil,
        origin: .manual
      )
    )

    guard case .executable(_, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(arguments == ["-new-tab", url.absoluteString])
  }

  @Test(
    arguments: [
      "org.mozilla.firefox|/Users/private-user/Firefox/Profiles/id-only|normal",
      "org.mozilla.firefox|Legacy Name Only|normal",
    ]
  )
  func firefoxRejectsDetectedIDOnlyLegacyProfileWithoutExactPath(_ id: String) {
    #expect(throws: LaunchFailure.self) {
      try testLauncher().makePlan(
        url: url,
        application: application(family: .firefox),
        target: target(id: id, family: .firefox, profile: nil)
      )
    }
  }

  @Test func firefoxRejectsPathShapedManualIDOnlyLegacyProfileWithoutExactPath() {
    #expect(throws: LaunchFailure.self) {
      try testLauncher().makePlan(
        url: url,
        application: application(family: .firefox),
        target: target(
          id: "manual|/Users/private-user/Firefox/Profiles/id-only",
          family: .firefox,
          profile: nil,
          origin: .manual
        )
      )
    }
  }

  @Test func chromiumPrivatePlanUsesExactProfileIncognitoAndURLTokens() throws {
    let launcher = testLauncher()

    let plan = try launcher.makePlan(
      url: url,
      application: application(family: .chromium),
      target: target(family: .chromium, profile: "Profile 1", mode: .private)
    )

    guard case .executable(_, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(arguments == ["--profile-directory=Profile 1", "--incognito", "https://example.com"])
  }

  @Test func firefoxRejectsNameOnlyManualProfileWithoutExactLaunchPath() throws {
    let launcher = testLauncher()

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: application(family: .firefox),
        target: target(family: .firefox, profile: "Same Name", origin: .manual)
      )
    }
  }

  @Test func firefoxRejectsRawIdentityManualProfileWithoutExactLaunchPath() throws {
    let launcher = testLauncher()

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: application(family: .firefox),
        target: target(
          family: .firefox,
          profile: "Same Name",
          profileIdentity: "/Users/private-user/Firefox/Profiles/legacy",
          origin: .manual
        )
      )
    }
  }

  @Test func firefoxRejectsAvailableDetectedNameOnlyLegacyProfile() throws {
    let launcher = testLauncher()

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: application(family: .firefox),
        target: target(family: .firefox, profile: "Same Name", origin: .detected)
      )
    }
  }

  @Test func firefoxTransientLaunchPathSelectsExactProfileWithoutUsingPersistedIdentity() throws {
    let launcher = testLauncher()
    let profilePath = "/profiles/one.default-release"

    let plan = try launcher.makePlan(
      url: url,
      application: application(family: .firefox),
      target: target(
        family: .firefox,
        profile: "Same Name",
        profileIdentity: "firefox-profile-v1:0123456789abcdef",
        profileLaunchPath: profilePath
      )
    )

    guard case .executable(_, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(arguments == ["-profile", profilePath, "-new-tab", url.absoluteString])
  }

  @Test func firefoxRejectsOpaqueProfileWhenTransientLaunchPathIsUnavailable() throws {
    let launcher = testLauncher()

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: application(family: .firefox),
        target: target(
          family: .firefox,
          profile: "Same Name",
          profileIdentity: FirefoxProfileIdentity.identifier(
            for: URL(fileURLWithPath: "/profiles/one", isDirectory: true)
          )
        )
      )
    }
  }

  @Test func firefoxRejectsPrivateManualProfileWithoutExactLaunchPath() throws {
    let launcher = testLauncher()

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: application(family: .firefox),
        target: target(family: .firefox, profile: "Same Name", mode: .private, origin: .manual)
      )
    }
  }

  @Test func safariNormalPlanUsesWorkspaceOpening() throws {
    let launcher = testLauncher()
    let safari = application(family: .safari, executable: nil)

    let plan = try launcher.makePlan(
      url: url,
      application: safari,
      target: target(family: .safari, profile: nil)
    )

    #expect(plan == .workspace(application: safari.applicationURL, url: url))
  }

  @Test(arguments: [
    target(family: .safari, profile: "Personal"),
    target(family: .safari, profile: nil, mode: .private),
  ])
  func safariRejectsProfileAndPrivateTargets(safariTarget: BrowserTarget) {
    let launcher = testLauncher()

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: application(family: .safari, executable: nil),
        target: safariTarget
      )
    }
  }

  @Test func mismatchedBrowserIDIsRejected() {
    let launcher = testLauncher()

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: application(family: .chromium),
        target: target(family: .firefox, profile: "work")
      )
    }
  }

  @Test func declaredFamilyMustMatchTrustedBundleFamily() {
    let launcher = testLauncher()
    let disguisedChrome = application(family: .firefox, bundleIdentifier: "com.google.Chrome")

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: disguisedChrome,
        target: target(family: .chromium, profile: "Profile 1")
      )
    }
  }

  @Test func unsupportedBundleIdentifierIsRejected() {
    let launcher = testLauncher()

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: application(family: .chromium, bundleIdentifier: "com.example.browser"),
        target: target(browserID: "com.example.browser", profile: "Profile 1")
      )
    }
  }

  @Test func missingPersistedExecutableDoesNotBlockTrustedLaunchResolution() async throws {
    let process = RecordingProcessRunner()
    let launcher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
        "com.google.Chrome": applicationURL
      ]),
      processRunner: process,
      workspace: RecordingWorkspace(),
      executableValidator: StubExecutableValidator(isExecutable: true)
    )

    try await launcher.launch(
      url: url,
      application: application(family: .chromium, executable: nil),
      target: target(family: .chromium, profile: "Profile 1")
    )
    #expect(process.invocations.count == 1)
  }

  @Test(arguments: [
    URL(fileURLWithPath: "/missing/Google Chrome"),
    URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Not Executable"),
  ])
  func invalidExecutableFailsBeforeProcessLaunch(invalidExecutable: URL) async {
    let process = RecordingProcessRunner()
    let validator = StubExecutableValidator(isExecutable: false)
    let launcher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
        "com.google.Chrome": applicationURL
      ]),
      processRunner: process,
      workspace: RecordingWorkspace(),
      executableValidator: validator
    )

    await #expect(throws: LaunchFailure.self) {
      try await launcher.launch(
        url: url,
        application: application(family: .chromium, executable: invalidExecutable),
        target: target(family: .chromium, profile: "Profile 1")
      )
    }
    #expect(
      validator.requestedURLs
        == [applicationURL.appending(path: "Contents/MacOS/Google Chrome")])
    #expect(process.invocations.isEmpty)
  }

  @Test(arguments: [AvailabilityKind.application, .target])
  func unavailableInputsFailBeforeAnySideEffect(kind: AvailabilityKind) async {
    let process = RecordingProcessRunner()
    let workspace = RecordingWorkspace()
    let launcher = BrowserLauncher(
      processRunner: process,
      workspace: workspace,
      executableValidator: StubExecutableValidator(isExecutable: true)
    )
    let app = application(family: .chromium, isAvailable: kind != .application)
    let unavailableTarget = target(
      family: .chromium,
      profile: "Profile 1",
      availability: kind == .target ? .unavailable : .available
    )

    await #expect(throws: LaunchFailure.self) {
      try await launcher.launch(url: url, application: app, target: unavailableTarget)
    }
    #expect(process.invocations.isEmpty)
    #expect(workspace.invocations.isEmpty)
  }

  @Test func shellMetacharactersRemainOneURLArgument() throws {
    let dangerousURL = URL(
      string: "https://example.com/a?x=%24%28touch%20%2Ftmp%2Fpwned%29%3B%26y=1")!
    let launcher = testLauncher()

    let plan = try launcher.makePlan(
      url: dangerousURL,
      application: application(family: .chromium),
      target: target(family: .chromium, profile: "Profile 1")
    )

    guard case .executable(_, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(arguments.count == 2)
    #expect(arguments.last == dangerousURL.absoluteString)
  }

  @Test func unicodeURLAndProfileRemainDistinctSingleTokens() throws {
    let unicodeURL = URL(string: "https://example.com/%E8%B7%AF%E5%BE%84?q=%F0%9F%8C%9F")!
    let profilePath = "/profiles/工作 👩🏽‍💻"
    let launcher = testLauncher()

    let plan = try launcher.makePlan(
      url: unicodeURL,
      application: application(family: .firefox),
      target: target(
        family: .firefox,
        profile: "工作 👩🏽‍💻",
        profileLaunchPath: profilePath,
        origin: .manual
      )
    )

    guard case .executable(_, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(arguments == ["-profile", profilePath, "-new-tab", unicodeURL.absoluteString])
    #expect(arguments[1] == profilePath)
    #expect(arguments[3] == unicodeURL.absoluteString)
  }

  @Test func symlinkedExecutableEscapingResolvedBundleIsRejected() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(
      path: "PickViaLauncherTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? fileManager.removeItem(at: root) }

    let realBundle = root.appending(path: "Real Chrome.app", directoryHint: .isDirectory)
    let executableDirectory = realBundle.appending(
      path: "Contents/MacOS", directoryHint: .isDirectory)
    let outsideExecutable = root.appending(path: "outside-executable")
    let bundleSymlink = root.appending(path: "Google Chrome.app", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
    try Data().write(to: outsideExecutable)
    try fileManager.createSymbolicLink(
      at: executableDirectory.appending(path: "Google Chrome"),
      withDestinationURL: outsideExecutable
    )
    try fileManager.createSymbolicLink(at: bundleSymlink, withDestinationURL: realBundle)

    let launcher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
        "com.google.Chrome": bundleSymlink
      ]),
      processRunner: RecordingProcessRunner(),
      workspace: RecordingWorkspace(),
      executableValidator: StubExecutableValidator(isExecutable: true)
    )

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: application(family: .chromium),
        target: target(family: .chromium, profile: nil)
      )
    }
  }

  @Test func executeDispatchesExecutablePlanToInjectedProcessRunner() async throws {
    let process = RecordingProcessRunner()
    let launcher = BrowserLauncher(processRunner: process, workspace: RecordingWorkspace())
    let plan = LaunchPlan.executable(
      application: executableURL, arguments: ["-P", "work", url.absoluteString])

    try await launcher.execute(plan)

    #expect(
      process.invocations == [
        .init(application: executableURL, arguments: ["-P", "work", url.absoluteString])
      ])
  }

  @Test func executeDispatchesWorkspacePlanToInjectedWorkspace() async throws {
    let workspace = RecordingWorkspace()
    let launcher = BrowserLauncher(processRunner: RecordingProcessRunner(), workspace: workspace)
    let appURL = applicationURL

    try await launcher.execute(.workspace(application: appURL, url: url))

    #expect(workspace.invocations == [.init(application: appURL, url: url)])
  }

  @Test(arguments: [ExecutionKind.process, .workspace])
  func executionErrorsBecomeSanitizedLaunchFailures(kind: ExecutionKind) async {
    let underlying = NSError(
      domain: "BrowserLauncherTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "failed for https://secret.example/private"]
    )
    let process = RecordingProcessRunner(error: underlying)
    let workspace = RecordingWorkspace(error: underlying)
    let launcher = BrowserLauncher(processRunner: process, workspace: workspace)
    let plan: LaunchPlan =
      switch kind {
      case .process:
        .executable(application: executableURL, arguments: [url.absoluteString])
      case .workspace:
        .workspace(application: applicationURL, url: url)
      }

    do {
      try await launcher.execute(plan)
      Issue.record("Expected execution failure")
    } catch let failure as LaunchFailure {
      #expect(failure.message == "Could not open the selected browser target.")
      #expect(!failure.message.contains("secret.example"))
      #expect(!failure.message.contains(url.absoluteString))
    } catch {
      Issue.record("Expected LaunchFailure, got \(type(of: error))")
    }
  }
}

private let applicationURL = URL(fileURLWithPath: "/Applications/Browser.app", isDirectory: true)
private let executableURL = applicationURL.appending(path: "Contents/MacOS/Browser")

enum DuckDuckGoProfileField: CaseIterable, Sendable {
  case identifier
  case displayName
  case identity
  case launchPath
}

private func application(
  family: BrowserFamily,
  bundleIdentifier: String? = nil,
  executable: URL? = executableURL,
  isAvailable: Bool = true
) -> BrowserApplication {
  let bundleIdentifier = bundleIdentifier ?? bundleID(for: family)
  return BrowserApplication(
    id: bundleIdentifier,
    family: family,
    displayName: "Browser",
    bundleIdentifier: bundleIdentifier,
    applicationURL: applicationURL,
    executableURL: executable,
    isAvailable: isAvailable
  )
}

private func target(
  id: BrowserTarget.ID? = nil,
  family: BrowserFamily? = nil,
  browserID: BrowserApplication.ID? = nil,
  profile: String?,
  profileIdentity: String? = nil,
  profileLaunchPath: String? = nil,
  mode: BrowserMode = .normal,
  availability: BrowserTargetAvailability = .available,
  origin: BrowserTargetOrigin = .detected
) -> BrowserTarget {
  let browserID = browserID ?? bundleID(for: family ?? .chromium)
  return BrowserTarget(
    id: id ?? "target-\(profile ?? "default")-\(mode.rawValue)",
    browserID: browserID,
    label: "Target",
    profileIdentifier: profile,
    profileDisplayName: profile,
    profileIdentity: profileIdentity,
    profileLaunchPath: profileLaunchPath,
    mode: mode,
    isEnabled: true,
    sortOrder: 0,
    origin: origin,
    availability: availability
  )
}

private func duckDuckGoTarget(
  profileField: DuckDuckGoProfileField? = nil,
  mode: BrowserMode = .normal
) -> BrowserTarget {
  BrowserTarget(
    id: BrowserCatalog.targetID(
      bundleIdentifier: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
      profileIdentifier: nil,
      mode: mode
    ),
    browserID: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
    label: "DuckDuckGo",
    profileIdentifier: profileField == .identifier ? "Profile 1" : nil,
    profileDisplayName: profileField == .displayName ? "Profile 1" : nil,
    profileIdentity: profileField == .identity ? "profile-identity" : nil,
    profileLaunchPath: profileField == .launchPath ? "/profiles/one" : nil,
    mode: mode,
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: .available
  )
}

private func bundleID(for family: BrowserFamily) -> String {
  switch family {
  case .safari: "com.apple.Safari"
  case .duckDuckGo: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier
  case .chromium: "com.google.Chrome"
  case .firefox: "org.mozilla.firefox"
  }
}

private func testLauncher() -> BrowserLauncher {
  BrowserLauncher(
    trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
      "com.apple.Safari": applicationURL,
      "com.google.Chrome": applicationURL,
      "org.mozilla.firefox": applicationURL,
    ]),
    processRunner: RecordingProcessRunner(),
    workspace: RecordingWorkspace(),
    executableValidator: StubExecutableValidator(isExecutable: true)
  )
}

private func duckDuckGoLauncher(
  router: any DuckDuckGoRouting
) -> BrowserLauncher {
  BrowserLauncher(
    trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
      DuckDuckGoBuildCompatibilityChecker.bundleIdentifier: applicationURL
    ]),
    processRunner: RecordingProcessRunner(),
    workspace: RecordingWorkspace(),
    executableValidator: StubExecutableValidator(isExecutable: true),
    duckDuckGoRouter: router
  )
}

private actor RecordingDuckDuckGoRouter: DuckDuckGoRouting {
  struct Invocation: Equatable, Sendable {
    let url: URL
    let applicationURL: URL
    let mode: BrowserMode
  }

  private(set) var invocations: [Invocation] = []
  let errorCode: Int?

  init(errorCode: Int? = nil) {
    self.errorCode = errorCode
  }

  func open(
    url: URL,
    applicationURL: URL,
    mode: BrowserMode
  ) async throws {
    invocations.append(
      .init(url: url, applicationURL: applicationURL, mode: mode)
    )
    if let errorCode {
      throw NSError(domain: NSCocoaErrorDomain, code: errorCode)
    }
  }
}

private struct StubTrustedApplicationResolver: TrustedApplicationResolving {
  let urls: [String: URL]

  func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
    urls[bundleIdentifier]
  }
}

enum ExecutionKind: Sendable {
  case process
  case workspace
}

enum AvailabilityKind: Sendable {
  case application
  case target
}

private final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
  struct Invocation: Equatable {
    let application: URL
    let arguments: [String]
  }

  private(set) var invocations: [Invocation] = []
  private let error: (any Error)?

  init(error: (any Error)? = nil) {
    self.error = error
  }

  func run(executable application: URL, arguments: [String]) throws {
    invocations.append(.init(application: application, arguments: arguments))
    if let error { throw error }
  }
}

private final class RecordingWorkspace: WorkspaceOpening, @unchecked Sendable {
  struct Invocation: Equatable {
    let application: URL
    let url: URL
  }

  private(set) var invocations: [Invocation] = []
  private let error: (any Error)?

  init(error: (any Error)? = nil) {
    self.error = error
  }

  func open(_ url: URL, withApplicationAt application: URL) async throws {
    invocations.append(.init(application: application, url: url))
    if let error { throw error }
  }
}

private final class StubExecutableValidator: ExecutableValidating, @unchecked Sendable {
  private let isExecutable: Bool
  private(set) var requestedURLs: [URL] = []

  init(isExecutable: Bool) {
    self.isExecutable = isExecutable
  }

  func isExecutableFile(at url: URL) -> Bool {
    requestedURLs.append(url)
    return isExecutable
  }
}
