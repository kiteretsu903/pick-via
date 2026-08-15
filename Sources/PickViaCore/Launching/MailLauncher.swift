import Foundation

public enum MailLaunchPlan: Equatable, Sendable {
  case workspace(application: URL, url: URL)
}

public struct MailLauncher: Sendable {
  private static let launchFailure = LaunchFailure(
    message: "Could not open the selected mail app."
  )

  private let trustedApplicationResolver: any TrustedApplicationResolving
  private let workspace: any WorkspaceOpening
  private let pickViaBundleIdentifier: String

  public init(
    trustedApplicationResolver: any TrustedApplicationResolving = WorkspaceApplicationLocator(),
    workspace: any WorkspaceOpening = SystemWorkspace(),
    pickViaBundleIdentifier: String = Bundle.main.bundleIdentifier ?? ""
  ) {
    self.trustedApplicationResolver = trustedApplicationResolver
    self.workspace = workspace
    self.pickViaBundleIdentifier = pickViaBundleIdentifier
  }

  public func makePlan(
    url: URL,
    application: RoutedApplication,
    target: RouteTarget
  ) throws -> MailLaunchPlan {
    guard
      (try? URLValidator.validate(url))?.kind == .mail,
      case .mail = target.capability,
      application.id == target.applicationID,
      application.id == application.bundleIdentifier,
      application.isAvailable(for: .mail),
      target.availability == .available,
      application.bundleIdentifier != pickViaBundleIdentifier,
      let trustedApplicationURL = trustedApplicationResolver.applicationURL(
        forBundleIdentifier: application.bundleIdentifier
      )
    else {
      throw Self.launchFailure
    }

    return .workspace(application: trustedApplicationURL, url: url)
  }

  public func execute(_ plan: MailLaunchPlan) async throws {
    do {
      switch plan {
      case .workspace(let application, let url):
        try await workspace.open(url, withApplicationAt: application)
      }
    } catch {
      throw Self.launchFailure
    }
  }

  public func launch(
    url: URL,
    application: RoutedApplication,
    target: RouteTarget
  ) async throws {
    let plan = try makePlan(url: url, application: application, target: target)
    try await execute(plan)
  }
}
