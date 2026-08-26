#!/usr/bin/env swift
import AppKit
import Darwin
import Foundation

private let maximumInputBytes = 4_096
private let maximumRegistrationChecks = 50
private let registrationCheckDelay: TimeInterval = 0.1
private let maximumOpenAttempts = 10
private let openRetryDelay: TimeInterval = 0.15

struct RunningApplicationIdentity: Sendable {
  let processIdentifier: pid_t
  let bundleIdentifier: String?
  let canonicalBundleURL: URL?
}

struct ExpectedRunningApplicationIdentity: Sendable {
  let processIdentifier: pid_t
  let bundleIdentifier: String
  let canonicalBundleURL: URL

  func matches(_ candidate: RunningApplicationIdentity?) -> Bool {
    guard let candidate else { return false }
    return candidate.processIdentifier == processIdentifier
      && candidate.bundleIdentifier == bundleIdentifier
      && candidate.canonicalBundleURL == canonicalBundleURL
  }
}

enum BoundedOpenFailure: Equatable, Sendable {
  case openErrorsExhausted
  case identityMismatch
  case noAttempts
}

enum ExactApplicationRegistrationPolicy {
  static func wait(
    expected: ExpectedRunningApplicationIdentity,
    maximumChecks: Int,
    delayInterval: TimeInterval = registrationCheckDelay,
    snapshot: () -> [RunningApplicationIdentity],
    delay: (TimeInterval) -> Void
  ) -> Bool {
    guard maximumChecks > 0 else { return false }

    for check in 0..<maximumChecks {
      if snapshot().contains(where: expected.matches) {
        return true
      }
      if check + 1 < maximumChecks {
        delay(delayInterval)
      }
    }
    return false
  }
}

final class BoundedOpenCoordinator: @unchecked Sendable {
  typealias OpenCompletion = @Sendable (RunningApplicationIdentity?, (any Error)?) -> Void
  typealias OpenAttempt = @Sendable (@escaping OpenCompletion) -> Void
  typealias RetryAction = @Sendable () -> Void
  typealias RetryScheduler = @Sendable (TimeInterval, @escaping RetryAction) -> Void
  typealias FinalCompletion = @Sendable (Bool) -> Void

  private let expectedApplication: ExpectedRunningApplicationIdentity
  private let maximumAttempts: Int
  private let retryDelay: TimeInterval
  private let scheduleRetry: RetryScheduler
  private let lock = NSLock()
  private var attemptCount = 0
  private var activeAttemptID = 0
  private var handledAttemptID: Int?
  private var started = false
  private var finished = false
  private var failure: BoundedOpenFailure?
  private var attempt: OpenAttempt?
  private var finalCompletion: FinalCompletion?

  init(
    expectedApplication: ExpectedRunningApplicationIdentity,
    maximumAttempts: Int,
    retryDelay: TimeInterval = openRetryDelay,
    scheduleRetry: @escaping RetryScheduler
  ) {
    self.expectedApplication = expectedApplication
    self.maximumAttempts = maximumAttempts
    self.retryDelay = retryDelay
    self.scheduleRetry = scheduleRetry
  }

  func start(
    attempt: @escaping OpenAttempt,
    completion: @escaping FinalCompletion
  ) {
    lock.lock()
    guard !started else {
      lock.unlock()
      return
    }
    started = true
    self.attempt = attempt
    finalCompletion = completion
    lock.unlock()
    runAttempt()
  }

  func failureReason() -> BoundedOpenFailure? {
    lock.lock()
    defer { lock.unlock() }
    return failure
  }

  private func runAttempt() {
    var attemptToRun: OpenAttempt?
    var attemptID = 0
    var completionToCall: FinalCompletion?

    lock.lock()
    if !finished, maximumAttempts > 0, attemptCount < maximumAttempts {
      attemptCount += 1
      activeAttemptID += 1
      attemptID = activeAttemptID
      handledAttemptID = nil
      attemptToRun = attempt
    } else {
      failure = .noAttempts
      completionToCall = finishLocked()
    }
    lock.unlock()

    if let completionToCall {
      completionToCall(false)
      return
    }
    guard let attemptToRun else { return }
    let currentAttemptID = attemptID

    attemptToRun { [self] application, error in
      handleCompletion(application, error: error, attemptID: currentAttemptID)
    }
  }

  private func handleCompletion(
    _ application: RunningApplicationIdentity?,
    error: (any Error)?,
    attemptID: Int
  ) {
    var completionToCall: FinalCompletion?
    var result = false
    var shouldRetry = false

    lock.lock()
    guard
      !finished,
      activeAttemptID == attemptID,
      handledAttemptID != attemptID
    else {
      lock.unlock()
      return
    }
    handledAttemptID = attemptID

    if error == nil {
      result = expectedApplication.matches(application)
      if !result {
        failure = .identityMismatch
      }
      completionToCall = finishLocked()
    } else if attemptCount < maximumAttempts {
      shouldRetry = true
    } else {
      failure = .openErrorsExhausted
      completionToCall = finishLocked()
    }
    lock.unlock()

    if shouldRetry {
      scheduleRetry(retryDelay) { [self] in
        runAttempt()
      }
    } else {
      completionToCall?(result)
    }
  }

  private func finishLocked() -> FinalCompletion? {
    guard !finished else { return nil }
    finished = true
    attempt = nil
    defer { finalCompletion = nil }
    return finalCompletion
  }
}

#if !PICKVIA_OPEN_WITH_APP_POLICY_TESTS
  private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(EXIT_FAILURE)
  }

  private func readBoundedInput() -> Data {
    var input = Data()
    do {
      while input.count <= maximumInputBytes {
        let remainingProbeBytes = maximumInputBytes + 1 - input.count
        let chunk =
          try FileHandle.standardInput.read(
            upToCount: min(1_024, remainingProbeBytes)
          ) ?? Data()
        if chunk.isEmpty { return input }
        input.append(chunk)
      }
    } catch {
      fail("invalid input")
    }
    fail("invalid input")
  }

  private func canonicalURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func runHelper() -> Never {
    guard
      CommandLine.arguments.count == 3,
      let expectedProcessIdentifier = pid_t(CommandLine.arguments[2]),
      expectedProcessIdentifier > 0
    else {
      fail("invalid arguments")
    }

    let rawApplicationPath = CommandLine.arguments[1]
    let lexicalApplicationURL = URL(fileURLWithPath: rawApplicationPath, isDirectory: true)
    guard
      rawApplicationPath.hasPrefix("/"),
      lexicalApplicationURL.path == rawApplicationPath,
      lexicalApplicationURL.pathExtension.lowercased() == "app"
    else {
      fail("invalid application")
    }

    let input = readBoundedInput()
    guard
      !input.isEmpty,
      input.count <= maximumInputBytes,
      let rawURL = String(data: input, encoding: .utf8),
      !rawURL.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      let url = URL(string: rawURL),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host != nil
    else {
      fail("invalid input")
    }

    do {
      let values = try lexicalApplicationURL.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        fail("invalid application")
      }
    } catch {
      fail("invalid application")
    }

    let expectedCanonicalBundleURL = canonicalURL(lexicalApplicationURL)
    guard
      let bundle = Bundle(url: lexicalApplicationURL),
      let expectedBundleIdentifier = bundle.bundleIdentifier,
      !expectedBundleIdentifier.isEmpty,
      canonicalURL(bundle.bundleURL) == expectedCanonicalBundleURL
    else {
      fail("invalid application")
    }
    let expectedApplication = ExpectedRunningApplicationIdentity(
      processIdentifier: expectedProcessIdentifier,
      bundleIdentifier: expectedBundleIdentifier,
      canonicalBundleURL: expectedCanonicalBundleURL
    )

    let registered = ExactApplicationRegistrationPolicy.wait(
      expected: expectedApplication,
      maximumChecks: maximumRegistrationChecks,
      snapshot: {
        NSRunningApplication.runningApplications(
          withBundleIdentifier: expectedBundleIdentifier
        ).map {
          RunningApplicationIdentity(
            processIdentifier: $0.processIdentifier,
            bundleIdentifier: $0.bundleIdentifier,
            canonicalBundleURL: $0.bundleURL.map(canonicalURL)
          )
        }
      },
      delay: Thread.sleep(forTimeInterval:)
    )
    guard registered else {
      fail("application unavailable")
    }

    let coordinator = BoundedOpenCoordinator(
      expectedApplication: expectedApplication,
      maximumAttempts: maximumOpenAttempts,
      scheduleRetry: { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
      }
    )
    coordinator.start(
      attempt: { completion in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open(
          [url],
          withApplicationAt: lexicalApplicationURL,
          configuration: configuration
        ) { application, error in
          completion(
            application.map {
              RunningApplicationIdentity(
                processIdentifier: $0.processIdentifier,
                bundleIdentifier: $0.bundleIdentifier,
                canonicalBundleURL: $0.bundleURL.map(canonicalURL)
              )
            },
            error
          )
        }
      },
      completion: { succeeded in
        if succeeded {
          exit(EXIT_SUCCESS)
        }
        switch coordinator.failureReason() {
        case .identityMismatch:
          fail("open identity mismatch")
        case .openErrorsExhausted, .noAttempts, nil:
          fail("open unavailable")
        }
      }
    )
    dispatchMain()
  }

  runHelper()
#endif
