import Foundation
import Testing

@testable import PickViaCore

struct BrowserLauncherTests {
  private let url = URL(string: "https://example.com")!

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
      trustedBrowserResolver: StubTrustedBrowserResolver(urls: [
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

  @Test func launchFailsWhenSupportedBundleCannotBeResolvedCurrently() {
    let launcher = BrowserLauncher(
      trustedBrowserResolver: StubTrustedBrowserResolver(urls: [:]),
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

  @Test func unprofiledChromiumAndFirefoxPlansUseBrowserLevelArguments() throws {
    let launcher = testLauncher()

    let chromium = try launcher.makePlan(
      url: url,
      application: application(family: .chromium),
      target: target(family: .chromium, profile: nil)
    )
    let firefoxPrivate = try launcher.makePlan(
      url: url,
      application: application(family: .firefox),
      target: target(family: .firefox, profile: nil, mode: .private)
    )

    guard case .executable(_, let chromiumArguments) = chromium,
      case .executable(_, let firefoxArguments) = firefoxPrivate
    else {
      Issue.record("Expected executable plans")
      return
    }
    #expect(chromiumArguments == [url.absoluteString])
    #expect(firefoxArguments == ["-private-window", url.absoluteString])
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

  @Test func firefoxNormalPlanUsesExactProfileNewTabAndURLTokens() throws {
    let launcher = testLauncher()

    let plan = try launcher.makePlan(
      url: url,
      application: application(family: .firefox),
      target: target(family: .firefox, profile: "work")
    )

    guard case .executable(_, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(arguments == ["-P", "work", "-new-tab", "https://example.com"])
  }

  @Test func firefoxDurableIdentityUsesPathSelectorInsteadOfDuplicateProfileName() throws {
    let launcher = testLauncher()
    let profilePath = "/profiles/one.default-release"

    let plan = try launcher.makePlan(
      url: url,
      application: application(family: .firefox),
      target: target(
        family: .firefox,
        profile: "Same Name",
        profileIdentity: profilePath
      )
    )

    guard case .executable(_, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(arguments == ["-profile", profilePath, "-new-tab", url.absoluteString])
  }

  @Test func firefoxPrivatePlanUsesExactProfilePrivateWindowAndURLTokens() throws {
    let launcher = testLauncher()

    let plan = try launcher.makePlan(
      url: url,
      application: application(family: .firefox),
      target: target(family: .firefox, profile: "work", mode: .private)
    )

    guard case .executable(_, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(arguments == ["-P", "work", "-private-window", "https://example.com"])
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
      trustedBrowserResolver: StubTrustedBrowserResolver(urls: [
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
      trustedBrowserResolver: StubTrustedBrowserResolver(urls: [
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
    let profile = "工作 👩🏽‍💻"
    let launcher = testLauncher()

    let plan = try launcher.makePlan(
      url: unicodeURL,
      application: application(family: .firefox),
      target: target(family: .firefox, profile: profile)
    )

    guard case .executable(_, let arguments) = plan else {
      Issue.record("Expected executable launch plan")
      return
    }
    #expect(arguments == ["-P", profile, "-new-tab", unicodeURL.absoluteString])
    #expect(arguments[1] == profile)
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
      trustedBrowserResolver: StubTrustedBrowserResolver(urls: [
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
  family: BrowserFamily? = nil,
  browserID: BrowserApplication.ID? = nil,
  profile: String?,
  profileIdentity: String? = nil,
  mode: BrowserMode = .normal,
  availability: BrowserTargetAvailability = .available
) -> BrowserTarget {
  let browserID = browserID ?? bundleID(for: family ?? .chromium)
  return BrowserTarget(
    id: "target-\(profile ?? "default")-\(mode.rawValue)",
    browserID: browserID,
    label: "Target",
    profileIdentifier: profile,
    profileDisplayName: profile,
    profileIdentity: profileIdentity,
    mode: mode,
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: availability
  )
}

private func bundleID(for family: BrowserFamily) -> String {
  switch family {
  case .safari: "com.apple.Safari"
  case .chromium: "com.google.Chrome"
  case .firefox: "org.mozilla.firefox"
  }
}

private func testLauncher() -> BrowserLauncher {
  BrowserLauncher(
    trustedBrowserResolver: StubTrustedBrowserResolver(urls: [
      "com.apple.Safari": applicationURL,
      "com.google.Chrome": applicationURL,
      "org.mozilla.firefox": applicationURL,
    ]),
    processRunner: RecordingProcessRunner(),
    workspace: RecordingWorkspace(),
    executableValidator: StubExecutableValidator(isExecutable: true)
  )
}

private struct StubTrustedBrowserResolver: TrustedBrowserResolving {
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
