import AppKit
import CoreServices
import Foundation

public struct DuckDuckGoApplicationSnapshot: Equatable, Sendable {
  public let processIdentifier: Int32
  public let bundleIdentifier: String?
  public let bundleURL: URL?
  public let executableURL: URL?
  public let launchDate: Date?
  public let isFinishedLaunching: Bool
  public let isTerminated: Bool

  public init(
    processIdentifier: Int32,
    bundleIdentifier: String?,
    bundleURL: URL?,
    executableURL: URL?,
    launchDate: Date?,
    isFinishedLaunching: Bool,
    isTerminated: Bool
  ) {
    self.processIdentifier = processIdentifier
    self.bundleIdentifier = bundleIdentifier
    self.bundleURL = bundleURL
    self.executableURL = executableURL
    self.launchDate = launchDate
    self.isFinishedLaunching = isFinishedLaunching
    self.isTerminated = isTerminated
  }
}

public struct DuckDuckGoApplicationLaunchRequest: Equatable, Sendable {
  public let applicationURL: URL
  public let urls: [URL]
  public let createsNewApplicationInstance: Bool
  public let arguments: [String]
  public let environment: [String: String]
  public let activates: Bool

  public init(
    applicationURL: URL,
    urls: [URL],
    createsNewApplicationInstance: Bool,
    arguments: [String],
    environment: [String: String],
    activates: Bool
  ) {
    self.applicationURL = applicationURL
    self.urls = urls
    self.createsNewApplicationInstance = createsNewApplicationInstance
    self.arguments = arguments
    self.environment = environment
    self.activates = activates
  }
}

public protocol DuckDuckGoApplicationManaging: Sendable {
  func runningApplications(bundleIdentifier: String) async -> [DuckDuckGoApplicationSnapshot]
  func launch(_ request: DuckDuckGoApplicationLaunchRequest) async throws
    -> DuckDuckGoApplicationSnapshot
  func snapshot(processIdentifier: Int32) async -> DuckDuckGoApplicationSnapshot?
  func waitUntilFinishedLaunching(
    processIdentifier: Int32,
    timeout: Duration
  ) async throws -> DuckDuckGoApplicationSnapshot
  func activate(processIdentifier: Int32) async -> Bool
  func terminate(processIdentifier: Int32) async -> Bool
  func terminationEvents() async -> AsyncStream<Void>
}

extension DuckDuckGoApplicationManaging {
  public func terminationEvents() async -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }
}

// NotificationCenter supports removing observers from any thread. This immutable owner
// keeps the token alive for exactly the lifetime of the stream.
private final class DuckDuckGoTerminationObservation: @unchecked Sendable {
  let center: NotificationCenter
  let token: any NSObjectProtocol

  @MainActor init(continuation: AsyncStream<Void>.Continuation) {
    center = NSWorkspace.shared.notificationCenter
    token = center.addObserver(
      forName: NSWorkspace.didTerminateApplicationNotification,
      object: nil, queue: .main
    ) { notification in
      if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
        as? NSRunningApplication,
        application.bundleIdentifier == DuckDuckGoBuildCompatibilityChecker.bundleIdentifier
      {
        continuation.yield(())
      }
    }
  }

  func cancel() { center.removeObserver(token) }
  deinit { cancel() }
}

public enum DuckDuckGoApplicationManagerError: Error, Equatable, Sendable {
  case launchReturnedNoApplication
  case invalidProcessIdentifier
  case applicationDisappeared(processIdentifier: Int32)
  case applicationTerminated(processIdentifier: Int32)
  case launchTimedOut(processIdentifier: Int32)
}

public enum DuckDuckGoAppleEvent: Equatable, Sendable {
  case reopen
  case openURL(URL)
}

public protocol DuckDuckGoAppleEventSending: Sendable {
  func send(
    _ event: DuckDuckGoAppleEvent,
    processIdentifier: Int32
  ) async throws
}

@MainActor
public struct SystemDuckDuckGoApplicationManager: DuckDuckGoApplicationManaging {
  public nonisolated init() {}

  public func terminationEvents() async -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let observer = DuckDuckGoTerminationObservation(continuation: continuation)
    continuation.onTermination = { @Sendable _ in observer.cancel() }
    return stream
  }

  public func runningApplications(bundleIdentifier: String) async
    -> [DuckDuckGoApplicationSnapshot]
  {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(
      Self.snapshot(from:))
  }

  public func launch(_ request: DuckDuckGoApplicationLaunchRequest) async throws
    -> DuckDuckGoApplicationSnapshot
  {
    let configuration = Self.configuration(for: request)
    let application = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<NSRunningApplication, any Error>) in
      let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = {
        application, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let application {
          continuation.resume(returning: application)
        } else {
          continuation.resume(
            throwing: DuckDuckGoApplicationManagerError.launchReturnedNoApplication)
        }
      }

      if request.urls.isEmpty {
        NSWorkspace.shared.openApplication(
          at: request.applicationURL,
          configuration: configuration,
          completionHandler: completion
        )
      } else {
        NSWorkspace.shared.open(
          request.urls,
          withApplicationAt: request.applicationURL,
          configuration: configuration,
          completionHandler: completion
        )
      }
    }
    return try Self.validatedLaunchSnapshot(Self.snapshot(from: application))
  }

  public func snapshot(processIdentifier: Int32) async -> DuckDuckGoApplicationSnapshot? {
    guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
      return nil
    }
    return Self.snapshot(from: application)
  }

  public func waitUntilFinishedLaunching(
    processIdentifier: Int32,
    timeout: Duration
  ) async throws -> DuckDuckGoApplicationSnapshot {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)

    while true {
      guard let value = await snapshot(processIdentifier: processIdentifier) else {
        throw DuckDuckGoApplicationManagerError.applicationDisappeared(
          processIdentifier: processIdentifier)
      }
      guard !value.isTerminated else {
        throw DuckDuckGoApplicationManagerError.applicationTerminated(
          processIdentifier: processIdentifier)
      }
      if value.isFinishedLaunching {
        return value
      }
      guard clock.now < deadline else {
        throw DuckDuckGoApplicationManagerError.launchTimedOut(
          processIdentifier: processIdentifier)
      }

      let nextPoll = clock.now.advanced(by: .milliseconds(50))
      try await clock.sleep(until: nextPoll < deadline ? nextPoll : deadline)
    }
  }

  public func activate(processIdentifier: Int32) async -> Bool {
    NSRunningApplication(processIdentifier: processIdentifier)?.activate() ?? false
  }

  public func terminate(processIdentifier: Int32) async -> Bool {
    NSRunningApplication(processIdentifier: processIdentifier)?.terminate() ?? false
  }

  static func configuration(
    for request: DuckDuckGoApplicationLaunchRequest
  ) -> NSWorkspace.OpenConfiguration {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = request.createsNewApplicationInstance
    configuration.arguments = request.arguments
    configuration.environment = request.environment
    configuration.activates = request.activates
    configuration.allowsRunningApplicationSubstitution = false
    configuration.promptsUserIfNeeded = false
    configuration.addsToRecentItems = false
    return configuration
  }

  nonisolated static func validatedLaunchSnapshot(
    _ snapshot: DuckDuckGoApplicationSnapshot
  ) throws -> DuckDuckGoApplicationSnapshot {
    guard snapshot.processIdentifier > 0 else {
      throw DuckDuckGoApplicationManagerError.invalidProcessIdentifier
    }
    return snapshot
  }

  private static func snapshot(
    from application: NSRunningApplication
  ) -> DuckDuckGoApplicationSnapshot {
    DuckDuckGoApplicationSnapshot(
      processIdentifier: application.processIdentifier,
      bundleIdentifier: application.bundleIdentifier,
      bundleURL: application.bundleURL,
      executableURL: application.executableURL,
      launchDate: application.launchDate,
      isFinishedLaunching: application.isFinishedLaunching,
      isTerminated: application.isTerminated
    )
  }
}

public struct SystemDuckDuckGoAppleEventSender: DuckDuckGoAppleEventSending {
  static let sendOptions = NSAppleEventDescriptor.SendOptions(
    rawValue: UInt(kAEWaitReply | kAENeverInteract | kAEDoNotPromptForUserConsent)
  )

  public init() {}

  public func send(
    _ event: DuckDuckGoAppleEvent,
    processIdentifier: Int32
  ) async throws {
    let value = Self.descriptor(for: event, processIdentifier: processIdentifier)
    do {
      let reply = try value.sendEvent(options: Self.sendOptions, timeout: 5)
      try Self.validateReply(reply)
    } catch let error as DuckDuckGoRoutingError {
      throw error
    } catch {
      let failure = error as NSError
      guard failure.domain == NSOSStatusErrorDomain else { throw error }
      throw Self.routingError(for: failure.code)
    }
  }

  static func validateReply(_ reply: NSAppleEventDescriptor) throws {
    let code = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0
    guard code == 0 else { throw routingError(for: Int(code)) }
  }

  static func routingError(for code: Int) -> DuckDuckGoRoutingError {
    switch code {
    case Int(errAEEventNotPermitted), -1744: .automationRequired
    case Int(errAETimeout): .eventTimedOut
    default: .eventRejected
    }
  }

  static func descriptor(
    for event: DuckDuckGoAppleEvent,
    processIdentifier: Int32
  ) -> NSAppleEventDescriptor {
    let eventClass: AEEventClass
    let eventID: AEEventID
    switch event {
    case .reopen:
      eventClass = AEEventClass(kCoreEventClass)
      eventID = AEEventID(kAEReopenApplication)
    case .openURL:
      eventClass = 0x4755_524C
      eventID = 0x4755_524C
    }

    let value = NSAppleEventDescriptor(
      eventClass: eventClass,
      eventID: eventID,
      targetDescriptor: NSAppleEventDescriptor(processIdentifier: processIdentifier),
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    if case .openURL(let url) = event {
      value.setParam(
        NSAppleEventDescriptor(string: url.absoluteString),
        forKeyword: keyDirectObject
      )
    }
    return value
  }
}
