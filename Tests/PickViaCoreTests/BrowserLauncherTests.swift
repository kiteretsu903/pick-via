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

  @Test(arguments: [ProfileEvidenceField.displayName, .identity, .launchPath])
  func chromiumRejectsProfileEvidenceWithoutIdentifier(field: ProfileEvidenceField) {
    #expect(throws: LaunchFailure.self) {
      try testLauncher().makePlan(
        url: url,
        application: application(family: .chromium),
        target: profileEvidenceTarget(browserID: "com.google.Chrome", field: field)
      )
    }
  }

  @Test(arguments: EmptyIdentifierCompanion.allCases)
  func chromiumRejectsEmptyIdentifierWithProfileEvidence(companion: EmptyIdentifierCompanion) {
    #expect(throws: LaunchFailure.self) {
      try testLauncher().makePlan(
        url: url,
        application: application(family: .chromium),
        target: emptyIdentifierTarget(companion: companion)
      )
    }
  }

  @Test func chromiumBrowserLevelTargetStillUsesDefaultProfile() throws {
    let plan = try testLauncher().makePlan(
      url: url,
      application: application(family: .chromium),
      target: target(family: .chromium, profile: nil)
    )

    guard case .executable(_, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(arguments == [url.absoluteString])
  }

  @Test(arguments: ProfileEvidenceField.allCases)
  func workspaceRejectsProfileEvidenceForIncompatibleProfileStrategy(
    field: ProfileEvidenceField
  ) {
    let descriptor = BrowserDescriptor(
      bundleIdentifier: "com.apple.Safari",
      family: .safari,
      displayName: "Safari",
      profileStrategy: .chromium(root: "unused"),
      launchStrategy: .workspace,
      privateStrategy: .unsupported
    )

    #expect(throws: LaunchFailure.self) {
      try launcher(descriptor: descriptor).makePlan(
        url: url,
        application: application(family: .safari, executable: nil),
        target: profileEvidenceTarget(browserID: descriptor.bundleIdentifier, field: field)
      )
    }
  }

  @Test(arguments: ProfileEvidenceField.allCases)
  func duckDuckGoRejectsProfileEvidenceForIncompatibleProfileStrategy(
    field: ProfileEvidenceField
  ) {
    let descriptor = BrowserDescriptor(
      bundleIdentifier: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
      family: .duckDuckGo,
      displayName: "DuckDuckGo",
      profileStrategy: .firefox(root: "unused"),
      launchStrategy: .duckDuckGo,
      privateStrategy: .duckDuckGoFire
    )

    #expect(throws: LaunchFailure.self) {
      try launcher(descriptor: descriptor).makePlan(
        url: url,
        application: application(family: .duckDuckGo, executable: nil),
        target: profileEvidenceTarget(browserID: descriptor.bundleIdentifier, field: field)
      )
    }
  }

  @Test func incompatibleDescriptorIsRejectedAtLaunchBoundaryForBrowserLevelTarget() {
    let descriptor = BrowserDescriptor(
      bundleIdentifier: "com.google.Chrome",
      family: .chromium,
      displayName: "Google Chrome",
      profileStrategy: .firefox(root: "unused"),
      launchStrategy: .chromium(
        executableRelativePath: "Contents/MacOS/Google Chrome",
        profileArgument: "--profile-directory="
      ),
      privateStrategy: .argument("--incognito")
    )

    #expect(throws: LaunchFailure.self) {
      try launcher(descriptor: descriptor).makePlan(
        url: url,
        application: application(family: .chromium),
        target: target(family: .chromium, profile: nil)
      )
    }
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

  @Test func safariTechnologyPreviewUsesOnlyItsTrustedWorkspaceApplication() throws {
    let trustedApplication = URL(
      fileURLWithPath: "/Applications/Safari Technology Preview.app", isDirectory: true)
    let launcher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
        "com.apple.SafariTechnologyPreview": trustedApplication
      ]),
      processRunner: RecordingProcessRunner(),
      workspace: RecordingWorkspace(),
      executableValidator: StubExecutableValidator(isExecutable: true)
    )
    let preview = application(
      family: .safari,
      bundleIdentifier: "com.apple.SafariTechnologyPreview",
      executable: nil
    )
    let previewTarget = target(
      id: "com.apple.SafariTechnologyPreview||normal",
      browserID: "com.apple.SafariTechnologyPreview",
      profile: nil
    )

    let plan = try launcher.makePlan(url: url, application: preview, target: previewTarget)

    #expect(plan == .workspace(application: trustedApplication, url: url))
  }

  @Test(arguments: newChannelLaunchExpectations)
  func newChannelPlansUseExactTrustedExecutableAndArguments(
    _ expectation: ChannelLaunchExpectation
  ) throws {
    let trustedApplication = URL(
      fileURLWithPath: "/Applications/\(expectation.applicationName).app",
      isDirectory: true
    )
    let executable = trustedApplication.appending(path: expectation.executableRelativePath)
    let validator = StubExecutableValidator(isExecutable: true)
    let launcher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
        expectation.bundleIdentifier: trustedApplication
      ]),
      processRunner: RecordingProcessRunner(),
      workspace: RecordingWorkspace(),
      executableValidator: validator
    )
    let channelApplication = BrowserApplication(
      id: expectation.bundleIdentifier,
      family: expectation.family,
      displayName: expectation.applicationName,
      bundleIdentifier: expectation.bundleIdentifier,
      applicationURL: URL(fileURLWithPath: "/tmp/Substituted.app", isDirectory: true),
      executableURL: URL(fileURLWithPath: "/tmp/substituted-executable"),
      isAvailable: true
    )

    func channelTarget(profiled: Bool, mode: BrowserMode) -> BrowserTarget {
      let profile = profiled ? "PickVia E2E" : nil
      return target(
        id: BrowserCatalog.targetID(
          bundleIdentifier: expectation.bundleIdentifier,
          profileIdentifier: profile,
          mode: mode
        ),
        browserID: expectation.bundleIdentifier,
        profile: profile,
        profileLaunchPath: profiled ? expectation.profileLaunchPath : nil,
        mode: mode
      )
    }

    let normalPlan = try launcher.makePlan(
      url: url,
      application: channelApplication,
      target: channelTarget(profiled: false, mode: .normal)
    )
    let profilePlan = try launcher.makePlan(
      url: url,
      application: channelApplication,
      target: channelTarget(profiled: true, mode: .normal)
    )
    let privatePlan = try launcher.makePlan(
      url: url,
      application: channelApplication,
      target: channelTarget(profiled: true, mode: .private)
    )

    #expect(
      normalPlan
        == .executable(application: executable, arguments: expectation.normalArguments))
    #expect(
      profilePlan
        == .executable(application: executable, arguments: expectation.profileArguments))
    #expect(
      privatePlan
        == .executable(application: executable, arguments: expectation.privateArguments))
    #expect(validator.requestedURLs == [executable, executable, executable])
  }

  @Test func crossEditionTargetMismatchNeverLaunchesAnotherChannel() async {
    let process = RecordingProcessRunner()
    let workspace = RecordingWorkspace()
    let validator = StubExecutableValidator(isExecutable: true)
    let canaryApplicationURL = URL(
      fileURLWithPath: "/Applications/Google Chrome Canary.app", isDirectory: true)
    let launcher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
        "com.google.Chrome.canary": canaryApplicationURL
      ]),
      processRunner: process,
      workspace: workspace,
      executableValidator: validator
    )
    let canaryApplication = application(
      family: .chromium,
      bundleIdentifier: "com.google.Chrome.canary"
    )
    let devTarget = target(
      id: "com.google.Chrome.dev|PickVia E2E|normal",
      browserID: "com.google.Chrome.dev",
      profile: "PickVia E2E"
    )

    await #expect(throws: LaunchFailure.self) {
      try await launcher.launch(
        url: url,
        application: canaryApplication,
        target: devTarget
      )
    }
    #expect(process.invocations.isEmpty)
    #expect(workspace.invocations.isEmpty)
    #expect(validator.requestedURLs.isEmpty)
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

  @Test func edgePrivatePlanUsesInPrivateArgument() throws {
    let edgeApplication = application(
      family: .chromium,
      bundleIdentifier: "com.microsoft.edgemac"
    )
    let launcher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
        "com.microsoft.edgemac": applicationURL
      ]),
      processRunner: RecordingProcessRunner(),
      workspace: RecordingWorkspace(),
      executableValidator: StubExecutableValidator(isExecutable: true)
    )

    let plan = try launcher.makePlan(
      url: url,
      application: edgeApplication,
      target: target(
        family: .chromium,
        browserID: "com.microsoft.edgemac",
        profile: "Profile 1",
        mode: .private
      )
    )

    guard case .executable(let executable, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(executable == applicationURL.appending(path: "Contents/MacOS/Microsoft Edge"))
    #expect(arguments == ["--profile-directory=Profile 1", "--inprivate", url.absoluteString])
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

  @Test(arguments: failClosedLaunchExpectations)
  func newFamiliesUseWorkspaceForNormalBrowserLevelTargets(
    _ expectation: FailClosedLaunchExpectation
  ) throws {
    let descriptor = try #require(
      BrowserDescriptor.descriptor(forBundleIdentifier: expectation.bundleIdentifier)
    )
    let browser = application(
      family: expectation.family,
      bundleIdentifier: expectation.bundleIdentifier,
      executable: nil
    )

    let plan = try launcher(descriptor: descriptor).makePlan(
      url: url,
      application: browser,
      target: target(
        family: expectation.family,
        browserID: expectation.bundleIdentifier,
        profile: nil
      )
    )

    #expect(plan == .workspace(application: applicationURL, url: url))
  }

  @Test(arguments: failClosedLaunchExpectations, ProfileEvidenceField.allCases)
  func newFamiliesRejectEveryProfileTarget(
    _ expectation: FailClosedLaunchExpectation,
    field: ProfileEvidenceField
  ) throws {
    let descriptor = try #require(
      BrowserDescriptor.descriptor(forBundleIdentifier: expectation.bundleIdentifier)
    )

    #expect(throws: LaunchFailure.self) {
      try launcher(descriptor: descriptor).makePlan(
        url: url,
        application: application(
          family: expectation.family,
          bundleIdentifier: expectation.bundleIdentifier,
          executable: nil
        ),
        target: profileEvidenceTarget(browserID: expectation.bundleIdentifier, field: field)
      )
    }
  }

  @Test(arguments: failClosedLaunchExpectations)
  func newFamiliesRejectPrivateTargets(_ expectation: FailClosedLaunchExpectation) throws {
    let descriptor = try #require(
      BrowserDescriptor.descriptor(forBundleIdentifier: expectation.bundleIdentifier)
    )

    #expect(throws: LaunchFailure.self) {
      try launcher(descriptor: descriptor).makePlan(
        url: url,
        application: application(
          family: expectation.family,
          bundleIdentifier: expectation.bundleIdentifier,
          executable: nil
        ),
        target: target(
          family: expectation.family,
          browserID: expectation.bundleIdentifier,
          profile: nil,
          mode: .private
        )
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

struct ChannelLaunchExpectation: Sendable {
  let bundleIdentifier: String
  let family: BrowserFamily
  let applicationName: String
  let executableRelativePath: String
  let profileLaunchPath: String?
  let normalArguments: [String]
  let profileArguments: [String]
  let privateArguments: [String]
}

struct FailClosedLaunchExpectation: Sendable {
  let bundleIdentifier: String
  let family: BrowserFamily
}

private let failClosedLaunchExpectations: [FailClosedLaunchExpectation] = [
  FailClosedLaunchExpectation(bundleIdentifier: "com.operasoftware.Opera", family: .opera),
  FailClosedLaunchExpectation(bundleIdentifier: "company.thebrowser.Browser", family: .arc),
  FailClosedLaunchExpectation(bundleIdentifier: "com.kagi.kagimacOS", family: .orion),
]

private let newChannelLaunchExpectations: [ChannelLaunchExpectation] = [
  chromiumChannelLaunch(
    "com.google.Chrome.dev", "Google Chrome Dev", "--incognito"),
  chromiumChannelLaunch(
    "com.google.Chrome.canary", "Google Chrome Canary", "--incognito"),
  chromiumChannelLaunch(
    "com.microsoft.edgemac.Beta", "Microsoft Edge Beta", "--inprivate"),
  chromiumChannelLaunch(
    "com.microsoft.edgemac.Dev", "Microsoft Edge Dev", "--inprivate"),
  chromiumChannelLaunch(
    "com.microsoft.edgemac.Canary", "Microsoft Edge Canary", "--inprivate"),
  chromiumChannelLaunch(
    "com.brave.Browser.beta", "Brave Browser Beta", "--incognito"),
  chromiumChannelLaunch(
    "com.brave.Browser.nightly", "Brave Browser Nightly", "--incognito"),
  chromiumChannelLaunch(
    "com.vivaldi.Vivaldi.snapshot", "Vivaldi Snapshot", "--incognito"),
  firefoxChannelLaunch(
    "org.mozilla.firefoxdeveloperedition", "Firefox Developer Edition"),
  firefoxChannelLaunch("org.mozilla.nightly", "Firefox Nightly"),
]

private func chromiumChannelLaunch(
  _ bundleIdentifier: String,
  _ applicationName: String,
  _ privateArgument: String
) -> ChannelLaunchExpectation {
  ChannelLaunchExpectation(
    bundleIdentifier: bundleIdentifier,
    family: .chromium,
    applicationName: applicationName,
    executableRelativePath: "Contents/MacOS/\(applicationName)",
    profileLaunchPath: nil,
    normalArguments: ["https://example.com"],
    profileArguments: ["--profile-directory=PickVia E2E", "https://example.com"],
    privateArguments: [
      "--profile-directory=PickVia E2E", privateArgument, "https://example.com",
    ]
  )
}

private func firefoxChannelLaunch(
  _ bundleIdentifier: String,
  _ applicationName: String
) -> ChannelLaunchExpectation {
  let profilePath = "/profiles/PickVia E2E"
  return ChannelLaunchExpectation(
    bundleIdentifier: bundleIdentifier,
    family: .firefox,
    applicationName: applicationName,
    executableRelativePath: "Contents/MacOS/firefox",
    profileLaunchPath: profilePath,
    normalArguments: ["-new-tab", "https://example.com"],
    profileArguments: ["-profile", profilePath, "-new-tab", "https://example.com"],
    privateArguments: ["-profile", profilePath, "-private-window", "https://example.com"]
  )
}

enum DuckDuckGoProfileField: CaseIterable, Sendable {
  case identifier
  case displayName
  case identity
  case launchPath
}

enum ProfileEvidenceField: CaseIterable, Sendable {
  case identifier
  case displayName
  case identity
  case launchPath
}

enum EmptyIdentifierCompanion: CaseIterable, Sendable {
  case none
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

private func profileEvidenceTarget(
  browserID: BrowserApplication.ID,
  field: ProfileEvidenceField
) -> BrowserTarget {
  BrowserTarget(
    id: "profile-evidence-\(field)",
    browserID: browserID,
    label: "Profile Evidence",
    profileIdentifier: field == .identifier ? "Profile 1" : nil,
    profileDisplayName: field == .displayName ? "Profile 1" : nil,
    profileIdentity: field == .identity ? "profile-identity" : nil,
    profileLaunchPath: field == .launchPath ? "/profiles/one" : nil,
    mode: .normal,
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: .available
  )
}

private func emptyIdentifierTarget(companion: EmptyIdentifierCompanion) -> BrowserTarget {
  BrowserTarget(
    id: "empty-identifier-\(companion)",
    browserID: "com.google.Chrome",
    label: "Empty Identifier",
    profileIdentifier: "",
    profileDisplayName: companion == .displayName ? "Profile 1" : nil,
    profileIdentity: companion == .identity ? "profile-identity" : nil,
    profileLaunchPath: companion == .launchPath ? "/profiles/one" : nil,
    mode: .normal,
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
  case .opera: "com.operasoftware.Opera"
  case .arc: "company.thebrowser.Browser"
  case .orion: "com.kagi.kagimacOS"
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

private func launcher(descriptor: BrowserDescriptor) -> BrowserLauncher {
  BrowserLauncher(
    trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
      descriptor.bundleIdentifier: applicationURL
    ]),
    processRunner: RecordingProcessRunner(),
    workspace: RecordingWorkspace(),
    executableValidator: StubExecutableValidator(isExecutable: true),
    duckDuckGoRouter: RecordingDuckDuckGoRouter(),
    descriptors: [descriptor]
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
