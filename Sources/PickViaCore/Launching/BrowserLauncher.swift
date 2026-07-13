import AppKit
import Foundation

public enum LaunchPlan: Equatable, Sendable {
  case executable(application: URL, arguments: [String])
  case workspace(application: URL, url: URL)
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

public struct BrowserLauncher: BrowserLaunching, Sendable {
  private static let launchFailure = LaunchFailure(
    message: "Could not open the selected browser target."
  )

  private let processRunner: any ProcessRunning
  private let workspace: any WorkspaceOpening
  private let executableValidator: any ExecutableValidating

  public init(
    processRunner: any ProcessRunning = SystemProcessRunner(),
    workspace: any WorkspaceOpening = SystemWorkspace(),
    executableValidator: any ExecutableValidating = FoundationExecutableValidator()
  ) {
    self.processRunner = processRunner
    self.workspace = workspace
    self.executableValidator = executableValidator
  }

  public func makePlan(
    url: URL,
    application: BrowserApplication,
    target: BrowserTarget
  ) throws -> LaunchPlan {
    guard
      application.id == target.browserID,
      application.id == application.bundleIdentifier,
      BrowserDescriptor.family(forBundleIdentifier: application.bundleIdentifier)
        == application.family,
      application.isAvailable,
      target.availability == .available
    else {
      throw Self.launchFailure
    }

    switch application.family {
    case .safari:
      guard target.profileIdentifier == nil, target.mode == .normal else {
        throw Self.launchFailure
      }
      return .workspace(application: application.applicationURL, url: url)

    case .chromium:
      guard
        let executable = application.executableURL,
        executableValidator.isExecutableFile(at: executable)
      else {
        throw Self.launchFailure
      }
      var arguments: [String] = []
      if let profile = target.profileIdentifier {
        arguments.append("--profile-directory=\(profile)")
      }
      if target.mode == .private {
        arguments.append("--incognito")
      }
      arguments.append(url.absoluteString)
      return .executable(application: executable, arguments: arguments)

    case .firefox:
      guard
        let executable = application.executableURL,
        executableValidator.isExecutableFile(at: executable)
      else {
        throw Self.launchFailure
      }
      var arguments: [String] = []
      if let profile = target.profileIdentifier {
        arguments.append(contentsOf: ["-P", profile])
      }
      arguments.append(target.mode == .private ? "-private-window" : "-new-tab")
      arguments.append(url.absoluteString)
      return .executable(application: executable, arguments: arguments)
    }
  }

  public func execute(_ plan: LaunchPlan) async throws {
    do {
      switch plan {
      case .executable(let application, let arguments):
        try processRunner.run(executable: application, arguments: arguments)
      case .workspace(let application, let url):
        try await workspace.open(url, withApplicationAt: application)
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
