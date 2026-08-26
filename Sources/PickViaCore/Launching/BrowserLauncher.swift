import AppKit
import Darwin
import Foundation

public enum LaunchPlan: Equatable, Sendable {
  case executable(application: URL, arguments: [String])
  case workspace(application: URL, url: URL)
  case duckDuckGo(application: URL, url: URL, mode: BrowserMode)
}

public protocol ProcessRunning: Sendable {
  @discardableResult
  func run(
    executable application: URL,
    arguments: [String]
  ) throws -> Int32
}

public protocol WorkspaceOpening: Sendable {
  @discardableResult
  func open(
    _ url: URL,
    withApplicationAt application: URL
  ) async throws -> Int32
}

public protocol ExecutableValidating: Sendable {
  func isExecutableFile(at url: URL) -> Bool
}

public protocol TrustedApplicationResolving: Sendable {
  func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
}

#if PICKVIA_E2E_AUTOMATION
  public struct BrowserLaunchProvenanceContext: Equatable, Sendable {
    public let sessionNonce: String
    public let requestNonce: String
    public let targetID: String
    public let expectedBundleIdentifier: String
    public let mode: BrowserMode

    public init(
      sessionNonce: String,
      requestNonce: String,
      targetID: String,
      expectedBundleIdentifier: String,
      mode: BrowserMode
    ) {
      self.sessionNonce = sessionNonce
      self.requestNonce = requestNonce
      self.targetID = targetID
      self.expectedBundleIdentifier = expectedBundleIdentifier
      self.mode = mode
    }
  }

  public enum BrowserLaunchProvenanceEvent: Equatable, Sendable {
    case observed(BrowserLaunchObservation)
    case launchUnproven(BrowserLaunchMechanism)
    case launchError(BrowserLaunchMechanism)
  }

  public protocol BrowserLaunchProvenanceSinking: Sendable {
    @discardableResult
    func record(
      _ event: BrowserLaunchProvenanceEvent,
      context: BrowserLaunchProvenanceContext
    ) -> Bool
  }
#endif

public struct FoundationExecutableValidator: ExecutableValidating {
  public init() {}

  public func isExecutableFile(at url: URL) -> Bool {
    FileManager.default.isExecutableFile(atPath: url.path)
  }
}

public struct SystemProcessRunner: ProcessRunning {
  public init() {}

  @discardableResult
  public func run(
    executable application: URL,
    arguments: [String]
  ) throws -> Int32 {
    let process = Process()
    process.executableURL = application
    process.arguments = arguments
    try process.run()
    guard process.processIdentifier > 0 else {
      throw BrowserLaunchObservationError.invalidProcessIdentifier
    }
    return process.processIdentifier
  }
}

struct WorkspaceApplicationSnapshot: Equatable, Sendable {
  let processIdentifier: Int32
  let bundleIdentifier: String?
  let bundleURL: URL?
}

protocol WorkspaceApplicationOpening: Sendable {
  func open(
    _ urls: [URL],
    withApplicationAt applicationURL: URL,
    configuration: NSWorkspace.OpenConfiguration,
    completionHandler:
      @escaping @Sendable (
        WorkspaceApplicationSnapshot?, (any Error)?
      ) -> Void
  )
}

private struct NSWorkspaceApplicationOpener: WorkspaceApplicationOpening {
  func open(
    _ urls: [URL],
    withApplicationAt applicationURL: URL,
    configuration: NSWorkspace.OpenConfiguration,
    completionHandler:
      @escaping @Sendable (
        WorkspaceApplicationSnapshot?, (any Error)?
      ) -> Void
  ) {
    NSWorkspace.shared.open(
      urls,
      withApplicationAt: applicationURL,
      configuration: configuration
    ) { application, error in
      completionHandler(
        application.map {
          WorkspaceApplicationSnapshot(
            processIdentifier: $0.processIdentifier,
            bundleIdentifier: $0.bundleIdentifier,
            bundleURL: $0.bundleURL
          )
        },
        error
      )
    }
  }
}

enum BrowserLaunchObservationError: Error, Equatable, Sendable {
  case invalidProcessIdentifier
  case workspaceApplicationIdentityUnavailable
  case workspaceCompletionDidNotReturnExactApplication
}

#if PICKVIA_E2E_AUTOMATION
  enum BrowserLaunchUnprovenObservationError: Error, Equatable, Sendable {
    case adapterObservationUnavailable
  }
#endif

public struct SystemWorkspace: WorkspaceOpening {
  private let opener: any WorkspaceApplicationOpening

  public init() {
    opener = NSWorkspaceApplicationOpener()
  }

  init(opener: any WorkspaceApplicationOpening) {
    self.opener = opener
  }

  @discardableResult
  public func open(
    _ url: URL,
    withApplicationAt application: URL
  ) async throws -> Int32 {
    let requestedApplicationURL = Self.canonicalFileURL(application)
    guard
      let requestedBundleIdentifier = Bundle(url: requestedApplicationURL)?.bundleIdentifier
    else {
      throw BrowserLaunchObservationError.workspaceApplicationIdentityUnavailable
    }

    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Int32, any Error>) in
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.allowsRunningApplicationSubstitution = false
      opener.open(
        [url],
        withApplicationAt: application,
        configuration: configuration
      ) { application, error in
        if let error {
          continuation.resume(throwing: error)
          return
        }
        do {
          continuation.resume(
            returning: try Self.processIdentifier(
              requestedApplicationURL: requestedApplicationURL,
              requestedBundleIdentifier: requestedBundleIdentifier,
              returnedApplications: application.map { [$0] }
            )
          )
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  static func processIdentifier(
    requestedApplicationURL: URL,
    requestedBundleIdentifier: String,
    returnedApplications: [WorkspaceApplicationSnapshot]?
  ) throws -> Int32 {
    guard
      let returnedApplications,
      returnedApplications.count == 1,
      let application = returnedApplications.first,
      application.bundleIdentifier == requestedBundleIdentifier,
      let returnedBundleURL = application.bundleURL,
      canonicalFileURL(returnedBundleURL).path
        == canonicalFileURL(requestedApplicationURL).path,
      application.processIdentifier > 0
    else {
      throw BrowserLaunchObservationError.workspaceCompletionDidNotReturnExactApplication
    }
    return application.processIdentifier
  }

  private static func canonicalFileURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
  }
}

public struct BrowserLauncher: Sendable {
  private static let launchFailure = LaunchFailure(
    message: "Could not open the selected browser target."
  )

  private let processRunner: any ProcessRunning
  private let workspace: any WorkspaceOpening
  private let executableValidator: any ExecutableValidating
  private let trustedApplicationResolver: any TrustedApplicationResolving
  private let duckDuckGoRouter: any DuckDuckGoRouting
  private let descriptors: [BrowserDescriptor]

  #if PICKVIA_E2E_AUTOMATION
    private let provenanceContext: BrowserLaunchProvenanceContext?
    private let provenanceSink: (any BrowserLaunchProvenanceSinking)?
  #endif

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
    #if PICKVIA_E2E_AUTOMATION
      provenanceContext = nil
      provenanceSink = nil
    #endif
  }

  #if PICKVIA_E2E_AUTOMATION
    public init(
      provenanceContext: BrowserLaunchProvenanceContext,
      provenanceSink: any BrowserLaunchProvenanceSinking
    ) {
      trustedApplicationResolver = WorkspaceApplicationLocator()
      processRunner = SystemProcessRunner()
      workspace = SystemWorkspace()
      executableValidator = FoundationExecutableValidator()
      duckDuckGoRouter = DuckDuckGoProcessCoordinator()
      descriptors = BrowserDescriptor.supported
      self.provenanceContext = provenanceContext
      self.provenanceSink = provenanceSink
    }
  #endif

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
    #if PICKVIA_E2E_AUTOMATION
      provenanceContext = nil
      provenanceSink = nil
    #endif
  }

  #if PICKVIA_E2E_AUTOMATION
    init(
      provenanceContext: BrowserLaunchProvenanceContext,
      provenanceSink: any BrowserLaunchProvenanceSinking,
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
      self.provenanceContext = provenanceContext
      self.provenanceSink = provenanceSink
    }
  #endif

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
      if !hasProfileEvidence, options.mode == .normal {
        return .workspace(application: trustedApplicationURL, url: url)
      }
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
        if let profileLaunchPath = options.profileLaunchPath {
          guard
            target.origin == .detected,
            let root = validatedChromiumProfileRoot(
              profileLaunchPath: profileLaunchPath,
              profileIdentifier: profile
            )
          else {
            throw Self.launchFailure
          }
          arguments.append("--user-data-dir=\(root.path)")
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

  private func validatedChromiumProfileRoot(
    profileLaunchPath: String,
    profileIdentifier: String
  ) -> URL? {
    guard
      (profileLaunchPath as NSString).isAbsolutePath,
      !profileIdentifier.isEmpty,
      !profileIdentifier.contains("/"),
      !profileIdentifier.contains("\\"),
      profileIdentifier != ".",
      profileIdentifier != "..",
      !(profileIdentifier as NSString).isAbsolutePath,
      !profileIdentifier.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }

    let profile = URL(fileURLWithPath: profileLaunchPath, isDirectory: true).standardizedFileURL
    let root = profile.deletingLastPathComponent().standardizedFileURL
    guard
      profile.lastPathComponent == profileIdentifier,
      profile.deletingLastPathComponent().path == root.path,
      root.appending(path: profileIdentifier, directoryHint: .isDirectory).standardizedFileURL.path
        == profile.path,
      Self.physicalType(at: root) == S_IFDIR,
      Self.physicalType(at: profile) == S_IFDIR,
      Self.physicalType(at: root.appending(path: "Local State")) == S_IFREG
    else { return nil }
    return root
  }

  private static func physicalType(at url: URL) -> mode_t? {
    guard url.isFileURL else { return nil }
    var status = stat()
    guard url.path.withCString({ lstat($0, &status) }) == 0 else { return nil }
    return status.st_mode & mode_t(S_IFMT)
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

  @discardableResult
  public func execute(_ plan: LaunchPlan) async throws -> BrowserLaunchObservation {
    do {
      return try await executeObservedPlan(plan)
    } catch {
      throw Self.launchFailure
    }
  }

  #if PICKVIA_E2E_AUTOMATION
    func executeWithProvenance(
      _ plan: LaunchPlan
    ) async throws -> BrowserLaunchObservation {
      guard let provenanceContext, let provenanceSink else {
        return try await execute(plan)
      }
      do {
        let observation = try await executeObservedPlan(plan)
        _ = provenanceSink.record(.observed(observation), context: provenanceContext)
        return observation
      } catch is BrowserLaunchUnprovenObservationError {
        _ = provenanceSink.record(
          .launchUnproven(Self.mechanism(for: plan)),
          context: provenanceContext
        )
        throw Self.launchFailure
      } catch {
        _ = provenanceSink.record(
          .launchError(Self.mechanism(for: plan)),
          context: provenanceContext
        )
        throw Self.launchFailure
      }
    }

    private static func mechanism(for plan: LaunchPlan) -> BrowserLaunchMechanism {
      switch plan {
      case .executable: .process
      case .workspace: .workspace
      case .duckDuckGo: .duckDuckGo
      }
    }
  #endif

  private func executeObservedPlan(
    _ plan: LaunchPlan
  ) async throws -> BrowserLaunchObservation {
    let processIdentifier: Int32
    let mechanism: BrowserLaunchMechanism
    do {
      switch plan {
      case .executable(let application, let arguments):
        processIdentifier = try processRunner.run(
          executable: application,
          arguments: arguments
        )
        mechanism = .process
      case .workspace(let application, let url):
        processIdentifier = try await workspace.open(url, withApplicationAt: application)
        mechanism = .workspace
      case .duckDuckGo(let application, let url, let mode):
        processIdentifier = try await duckDuckGoRouter.open(
          url: url,
          applicationURL: application,
          mode: mode
        )
        mechanism = .duckDuckGo
      }
    } catch BrowserLaunchObservationError.invalidProcessIdentifier,
      BrowserLaunchObservationError.workspaceCompletionDidNotReturnExactApplication,
      DuckDuckGoRoutingError.processIdentityMismatch
    {
      #if PICKVIA_E2E_AUTOMATION
        throw BrowserLaunchUnprovenObservationError.adapterObservationUnavailable
      #else
        throw BrowserLaunchObservationError.invalidProcessIdentifier
      #endif
    }
    guard
      let observation = BrowserLaunchObservation(
        processIdentifier: processIdentifier,
        mechanism: mechanism
      )
    else {
      #if PICKVIA_E2E_AUTOMATION
        throw BrowserLaunchUnprovenObservationError.adapterObservationUnavailable
      #else
        throw BrowserLaunchObservationError.invalidProcessIdentifier
      #endif
    }
    return observation
  }

  @discardableResult
  public func launch(
    url: URL,
    application: BrowserApplication,
    target: BrowserTarget
  ) async throws -> BrowserLaunchObservation {
    // Before makePlan succeeds there is no trustworthy mechanism to report. The E2E driver
    // therefore treats this bounded missing-provenance case as a harness failure.
    let plan = try makePlan(url: url, application: application, target: target)
    #if PICKVIA_E2E_AUTOMATION
      return try await executeWithProvenance(plan)
    #else
      return try await execute(plan)
    #endif
  }
}
