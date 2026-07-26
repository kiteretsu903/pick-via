import Foundation
import Testing

@testable import PickViaCore

struct MailLauncherTests {
  @Test func mailPlanUsesTrustedResolvedApplicationAndOriginalURL() throws {
    let url = try #require(URL(string: "mailto:person@example.com?body=secret"))
    let trustedURL = URL(
      fileURLWithPath: "/Applications/Trusted Mail.app",
      isDirectory: true
    )
    let launcher = makeLauncher(trustedURL: trustedURL)

    let plan = try launcher.makePlan(
      url: url,
      application: Fixtures.mailApplication,
      target: Fixtures.mailTarget
    )

    #expect(plan == .workspace(application: trustedURL, url: url))
  }

  @Test func substitutedPersistedApplicationURLIsIgnored() throws {
    let url = try #require(URL(string: "mailto:person@example.com"))
    let trustedURL = URL(
      fileURLWithPath: "/Applications/Trusted Mail.app",
      isDirectory: true
    )
    let substitutedApplication = RoutedApplication(
      id: Fixtures.mailApplication.id,
      displayName: Fixtures.mailApplication.displayName,
      bundleIdentifier: Fixtures.mailApplication.bundleIdentifier,
      capabilities: Fixtures.mailApplication.capabilities,
      applicationURL: URL(fileURLWithPath: "/tmp/Substituted.app", isDirectory: true)
    )

    let plan = try makeLauncher(trustedURL: trustedURL).makePlan(
      url: url,
      application: substitutedApplication,
      target: Fixtures.mailTarget
    )

    #expect(plan == .workspace(application: trustedURL, url: url))
  }

  @Test func browserTargetIsRejectedByMailLauncher() throws {
    let url = try #require(URL(string: "mailto:person@example.com"))

    #expect(throws: LaunchFailure.self) {
      try makeLauncher().makePlan(
        url: url,
        application: Fixtures.mailApplication,
        target: Fixtures.browserTarget
      )
    }
  }

  @Test func nonMailURLIsRejectedByMailLauncher() throws {
    let url = try #require(URL(string: "https://example.com/private"))

    #expect(throws: LaunchFailure.self) {
      try makeLauncher().makePlan(
        url: url,
        application: Fixtures.mailApplication,
        target: Fixtures.mailTarget
      )
    }
  }

  @Test func targetForAnotherApplicationIsRejected() throws {
    let url = try #require(URL(string: "mailto:person@example.com"))
    let mismatchedTarget = RouteTarget(
      id: Fixtures.mailTarget.id,
      applicationID: "com.example.OtherMail",
      label: Fixtures.mailTarget.label,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available,
      capability: .mail
    )

    #expect(throws: LaunchFailure.self) {
      try makeLauncher().makePlan(
        url: url,
        application: Fixtures.mailApplication,
        target: mismatchedTarget
      )
    }
  }

  @Test func unavailableMailApplicationIsRejected() throws {
    let url = try #require(URL(string: "mailto:person@example.com"))
    let unavailableApplication = RoutedApplication(
      id: Fixtures.mailApplication.id,
      displayName: Fixtures.mailApplication.displayName,
      bundleIdentifier: Fixtures.mailApplication.bundleIdentifier,
      capabilities: [.mail(isAvailable: false)],
      applicationURL: Fixtures.mailApplication.applicationURL
    )

    #expect(throws: LaunchFailure.self) {
      try makeLauncher().makePlan(
        url: url,
        application: unavailableApplication,
        target: Fixtures.mailTarget
      )
    }
  }

  @Test func unavailableMailTargetIsRejected() throws {
    let url = try #require(URL(string: "mailto:person@example.com"))
    let unavailableTarget = RouteTarget(
      id: Fixtures.mailTarget.id,
      applicationID: Fixtures.mailTarget.applicationID,
      label: Fixtures.mailTarget.label,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .unavailable,
      capability: .mail
    )

    #expect(throws: LaunchFailure.self) {
      try makeLauncher().makePlan(
        url: url,
        application: Fixtures.mailApplication,
        target: unavailableTarget
      )
    }
  }

  @Test func pickViaBundleIdentifierIsRejected() throws {
    let url = try #require(URL(string: "mailto:person@example.com"))
    let selfApplication = RoutedApplication(
      id: Fixtures.pickViaBundleIdentifier,
      displayName: "PickVia",
      bundleIdentifier: Fixtures.pickViaBundleIdentifier,
      capabilities: [.mail(isAvailable: true)],
      applicationURL: URL(fileURLWithPath: "/Applications/PickVia.app", isDirectory: true)
    )
    let selfTarget = RouteTarget(
      id: RouteTarget.mailID(bundleIdentifier: Fixtures.pickViaBundleIdentifier),
      applicationID: selfApplication.id,
      label: "PickVia",
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available,
      capability: .mail
    )

    #expect(throws: LaunchFailure.self) {
      try makeLauncher(
        trustedURL: selfApplication.applicationURL,
        pickViaBundleIdentifier: Fixtures.pickViaBundleIdentifier
      ).makePlan(
        url: url,
        application: selfApplication,
        target: selfTarget
      )
    }
  }

  @Test func resolverFailureRejectsPlanBeforeWorkspaceOpening() throws {
    let url = try #require(URL(string: "mailto:person@example.com"))
    let workspace = RecordingMailWorkspace()
    let launcher = MailLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [:]),
      workspace: workspace,
      pickViaBundleIdentifier: Fixtures.pickViaBundleIdentifier
    )

    #expect(throws: LaunchFailure.self) {
      try launcher.makePlan(
        url: url,
        application: Fixtures.mailApplication,
        target: Fixtures.mailTarget
      )
    }
    #expect(workspace.invocations.isEmpty)
  }

  @Test func executePassesOriginalMailtoURLAndTrustedApplicationToWorkspace() async throws {
    let url = try #require(
      URL(string: "mailto:person@example.com?subject=Private&body=secret")
    )
    let trustedURL = URL(
      fileURLWithPath: "/Applications/Trusted Mail.app",
      isDirectory: true
    )
    let workspace = RecordingMailWorkspace()
    let launcher = makeLauncher(trustedURL: trustedURL, workspace: workspace)

    try await launcher.execute(.workspace(application: trustedURL, url: url))

    #expect(
      workspace.invocations == [
        .init(application: trustedURL, url: url)
      ])
  }

  @Test func workspaceFailureBecomesSanitizedMailLaunchFailure() async throws {
    let url = try #require(URL(string: "mailto:person@example.com?body=secret"))
    let trustedURL = URL(
      fileURLWithPath: "/Applications/Trusted Mail.app",
      isDirectory: true
    )
    let workspace = RecordingMailWorkspace(
      error: NSError(
        domain: "MailLauncherTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "failed for \(url.absoluteString)"]
      )
    )
    let launcher = makeLauncher(trustedURL: trustedURL, workspace: workspace)

    do {
      try await launcher.execute(.workspace(application: trustedURL, url: url))
      Issue.record("Expected execution failure")
    } catch let failure as LaunchFailure {
      #expect(failure.message == "Could not open the selected mail app.")
      #expect(!failure.message.contains("person@example.com"))
      #expect(!failure.message.contains("secret"))
    } catch {
      Issue.record("Expected LaunchFailure, got \(type(of: error))")
    }
  }

  @Test func routeLauncherDispatchesMailTargetThroughMailStrategy() async throws {
    let url = try #require(URL(string: "mailto:person@example.com"))
    let trustedURL = URL(
      fileURLWithPath: "/Applications/Trusted Mail.app",
      isDirectory: true
    )
    let mailWorkspace = RecordingMailWorkspace()
    let mailLauncher = makeLauncher(trustedURL: trustedURL, workspace: mailWorkspace)
    let browserProcess = RecordingMailProcessRunner()
    let browserLauncher = BrowserLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [:]),
      processRunner: browserProcess,
      workspace: RecordingMailWorkspace(),
      executableValidator: AlwaysExecutableValidator()
    )
    let launcher = RouteLauncher(
      browserLauncher: browserLauncher,
      mailLauncher: mailLauncher
    )

    try await launcher.launch(
      url: url,
      application: Fixtures.mailApplication,
      target: Fixtures.mailTarget
    )

    #expect(
      mailWorkspace.invocations == [
        .init(application: trustedURL, url: url)
      ])
    #expect(browserProcess.invocationCount == 0)
  }

  private func makeLauncher(
    trustedURL: URL = Fixtures.trustedApplicationURL,
    workspace: RecordingMailWorkspace = RecordingMailWorkspace(),
    pickViaBundleIdentifier: String = Fixtures.pickViaBundleIdentifier
  ) -> MailLauncher {
    MailLauncher(
      trustedApplicationResolver: StubTrustedApplicationResolver(urls: [
        Fixtures.mailApplication.bundleIdentifier: trustedURL
      ]),
      workspace: workspace,
      pickViaBundleIdentifier: pickViaBundleIdentifier
    )
  }
}

private enum Fixtures {
  static let pickViaBundleIdentifier = "com.example.PickVia"
  static let trustedApplicationURL = URL(
    fileURLWithPath: "/Applications/Trusted Mail.app",
    isDirectory: true
  )

  static let mailApplication = RoutedApplication(
    id: "com.example.Mail",
    displayName: "Mail",
    bundleIdentifier: "com.example.Mail",
    capabilities: [.mail(isAvailable: true)],
    applicationURL: URL(fileURLWithPath: "/tmp/Persisted Mail.app", isDirectory: true)
  )

  static let mailTarget = RouteTarget(
    id: RouteTarget.mailID(bundleIdentifier: mailApplication.bundleIdentifier),
    applicationID: mailApplication.id,
    label: "Mail",
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: .available,
    capability: .mail
  )

  static let browserTarget = BrowserTarget(
    id: "browser-target",
    browserID: mailApplication.id,
    label: "Browser",
    profileIdentifier: nil,
    profileDisplayName: nil,
    mode: .normal,
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: .available
  )
}

private struct StubTrustedApplicationResolver: TrustedApplicationResolving {
  let urls: [String: URL]

  func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
    urls[bundleIdentifier]
  }
}

private final class RecordingMailWorkspace: WorkspaceOpening, @unchecked Sendable {
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

private final class RecordingMailProcessRunner: ProcessRunning, @unchecked Sendable {
  private(set) var invocationCount = 0

  func run(executable application: URL, arguments: [String]) throws {
    invocationCount += 1
  }
}

private struct AlwaysExecutableValidator: ExecutableValidating {
  func isExecutableFile(at url: URL) -> Bool { true }
}
