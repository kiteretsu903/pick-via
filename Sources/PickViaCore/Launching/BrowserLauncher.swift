import AppKit
import Foundation

public enum LaunchPlan: Equatable, Sendable {
  case executable(application: URL, arguments: [String])
  case workspace(application: URL, url: URL)
  case duckDuckGo(application: URL, url: URL, mode: BrowserMode)
}

public protocol ProcessRunning: Sendable {
  func run(executable application: URL, arguments: [String]) throws
}

public protocol WorkspaceOpening: Sendable {
  func open(_ url: URL, withApplicationAt application: URL) async throws
}

public protocol ExecutableValidating: Sendable {
  func isExecutableFile(at url: URL) -> Bool
}

public protocol TrustedApplicationResolving: Sendable {
  func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
}

public struct FoundationExecutableValidator: ExecutableValidating {
  public init() {}

  public func isExecutableFile(at url: URL) -> Bool {
    FileManager.default.isExecutableFile(atPath: url.path)
  }
}

public struct SystemProcessRunner: ProcessRunning {
  public init() {}

  public func run(executable application: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = application
    process.arguments = arguments
    try process.run()
  }
}

public struct SystemWorkspace: WorkspaceOpening {
  public init() {}

  public func open(_ url: URL, withApplicationAt application: URL) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.open(
        [url],
        withApplicationAt: application,
        configuration: configuration
      ) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

public struct BrowserLauncher: RouteLaunching, Sendable {
  private static let launchFailure = LaunchFailure(
    message: "Could not open the selected browser target."
  )

  private let processRunner: any ProcessRunning
  private let workspace: any WorkspaceOpening
  private let executableValidator: any ExecutableValidating
  private let trustedApplicationResolver: any TrustedApplicationResolving
  private let duckDuckGoRouter: any DuckDuckGoRouting
  private let descriptors: [BrowserDescriptor]

  public init(
    trustedApplicationResolver: any TrustedApplicationResolving = WorkspaceApplicationLocator(),
    processRunner: any ProcessRunning = SystemProcessRunner(),
    workspace: any WorkspaceOpening = SystemWorkspace(),
    executableValidator: any ExecutableValidating = FoundationExecutableValidator()
  ) {
    self.trustedApplicationResolver = trustedApplicationResolver
    self.processRunner = processRunner
    self.workspace = workspace
    self.executableValidator = executableValidator
    duckDuckGoRouter = DuckDuckGoProcessCoordinator()
    descriptors = BrowserDescriptor.supported
  }

  init(
    trustedApplicationResolver: any TrustedApplicationResolving,
    processRunner: any ProcessRunning,
    workspace: any WorkspaceOpening,
    executableValidator: any ExecutableValidating,
    duckDuckGoRouter: any DuckDuckGoRouting,
    descriptors: [BrowserDescriptor] = BrowserDescriptor.supported
  ) {
    self.trustedApplicationResolver = trustedApplicationResolver
    self.processRunner = processRunner
    self.workspace = workspace
    self.executableValidator = executableValidator
    self.duckDuckGoRouter = duckDuckGoRouter
    self.descriptors = descriptors
  }

  public func makePlan(
    url: URL,
    application: BrowserApplication,
    target: BrowserTarget
  ) throws -> LaunchPlan {
    guard
      case .browser(let options) = target.capability,
      application.id == target.applicationID,
      application.id == application.bundleIdentifier,
      let browserFamily = application.browserFamily,
      let descriptor = descriptors.first(where: {
        $0.bundleIdentifier == application.bundleIdentifier
      }),
      descriptor.family == browserFamily,
      descriptor.hasCompatibleStrategies,
      let trustedApplicationURL = trustedApplicationResolver.applicationURL(
        forBundleIdentifier: application.bundleIdentifier),
      application.isAvailable(for: .web),
      target.availability == .available
    else {
      throw Self.launchFailure
    }

    let hasProfileEvidence =
      options.profileIdentifier != nil
      || options.profileDisplayName != nil
      || options.profileIdentity != nil
      || options.profileLaunchPath != nil
    guard descriptor.supportsProfiles || !hasProfileEvidence else {
      throw Self.launchFailure
    }
    guard descriptor.supportsPrivateMode || options.mode == .normal else {
      throw Self.launchFailure
    }

    switch descriptor.launchStrategy {
    case .workspace:
      guard !hasProfileEvidence, options.mode == .normal else { throw Self.launchFailure }
      return .workspace(application: trustedApplicationURL, url: url)

    case .duckDuckGo:
      guard !hasProfileEvidence else { throw Self.launchFailure }
      if options.mode == .private {
        guard descriptor.privateStrategy == .duckDuckGoFire else {
          throw Self.launchFailure
        }
      }
      return .duckDuckGo(
        application: trustedApplicationURL,
        url: url,
        mode: options.mode
      )

    case .chromium(let relativeExecutable, let profileArgument):
      guard
        let executable = trustedExecutable(
          applicationURL: trustedApplicationURL,
          relativePath: relativeExecutable),
        executableValidator.isExecutableFile(at: executable)
      else {
        throw Self.launchFailure
      }
      var arguments: [String] = []
      if hasProfileEvidence {
        guard let profile = options.profileIdentifier, !profile.isEmpty else {
          throw Self.launchFailure
        }
        arguments.append("\(profileArgument)\(profile)")
      }
      if options.mode == .private {
        guard case .argument(let privateArgument) = descriptor.privateStrategy else {
          throw Self.launchFailure
        }
        arguments.append(privateArgument)
      }
      arguments.append(url.absoluteString)
      return .executable(application: executable, arguments: arguments)

    case .firefox(let relativeExecutable):
      guard
        let executable = trustedExecutable(
          applicationURL: trustedApplicationURL,
          relativePath: relativeExecutable),
        executableValidator.isExecutableFile(at: executable)
      else {
        throw Self.launchFailure
      }
      var arguments: [String] = []
      let isProfiled = BrowserCatalog.isProfileBearingFirefoxTarget(target)
      if let profilePath = options.profileLaunchPath {
        guard (profilePath as NSString).isAbsolutePath else { throw Self.launchFailure }
        arguments.append(contentsOf: ["-profile", profilePath])
      } else if isProfiled {
        throw Self.launchFailure
      }
      if options.mode == .private {
        guard case .argument(let privateArgument) = descriptor.privateStrategy else {
          throw Self.launchFailure
        }
        arguments.append(privateArgument)
      } else {
        arguments.append("-new-tab")
      }
      arguments.append(url.absoluteString)
      return .executable(application: executable, arguments: arguments)
    }
  }

  private func trustedExecutable(applicationURL: URL, relativePath: String) -> URL? {
    let application = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
    guard application.isFileURL, application.pathExtension == "app" else { return nil }
    let executable = application.appending(path: relativePath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let bundlePrefix = application.path.hasSuffix("/") ? application.path : application.path + "/"
    guard executable.path.hasPrefix(bundlePrefix) else { return nil }
    return executable
  }

  public func execute(_ plan: LaunchPlan) async throws {
    do {
      switch plan {
      case .executable(let application, let arguments):
        try processRunner.run(executable: application, arguments: arguments)
      case .workspace(let application, let url):
        try await workspace.open(url, withApplicationAt: application)
      case .duckDuckGo(let application, let url, let mode):
        try await duckDuckGoRouter.open(
          url: url,
          applicationURL: application,
          mode: mode
        )
      }
    } catch {
      throw Self.launchFailure
    }
  }

  public func launch(
    url: URL,
    application: BrowserApplication,
    target: BrowserTarget
  ) async throws {
    let plan = try makePlan(url: url, application: application, target: target)
    try await execute(plan)
  }
}
