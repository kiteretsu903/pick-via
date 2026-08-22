#!/usr/bin/env swift
import AppKit
import Darwin
import Foundation

private let maximumInputBytes = 4_096
private let maximumRegistrationChecks = 20
private let registrationCheckDelay: TimeInterval = 0.1
private let maximumOpenAttempts = 3
private let openRetryDelay: TimeInterval = 0.15

struct RunningApplicationIdentity {
  let bundleIdentifier: String?
  let canonicalBundleURL: URL?
}

enum ExactApplicationRegistrationPolicy {
  static func wait(
    expectedBundleIdentifier: String,
    expectedCanonicalBundleURL: URL,
    maximumChecks: Int,
    delayInterval: TimeInterval = registrationCheckDelay,
    snapshot: () -> [RunningApplicationIdentity],
    delay: (TimeInterval) -> Void
  ) -> Bool {
    guard maximumChecks > 0 else { return false }

    for check in 0..<maximumChecks {
      if snapshot().contains(where: {
        $0.bundleIdentifier == expectedBundleIdentifier
          && $0.canonicalBundleURL == expectedCanonicalBundleURL
      }) {
        return true
      }
      if check + 1 < maximumChecks {
        delay(delayInterval)
      }
    }
    return false
  }
}

final class BoundedOpenCoordinator {
  typealias OpenAttempt = (@escaping (Error?) -> Void) -> Void
  typealias RetryScheduler = (TimeInterval, @escaping () -> Void) -> Void

  private let maximumAttempts: Int
  private let retryDelay: TimeInterval
  private let scheduleRetry: RetryScheduler
  private var attemptCount = 0
  private var started = false
  private var finished = false

  init(
    maximumAttempts: Int,
    retryDelay: TimeInterval = openRetryDelay,
    scheduleRetry: @escaping RetryScheduler
  ) {
    self.maximumAttempts = maximumAttempts
    self.retryDelay = retryDelay
    self.scheduleRetry = scheduleRetry
  }

  func start(
    attempt: @escaping OpenAttempt,
    completion: @escaping (Bool) -> Void
  ) {
    guard !started else { return }
    started = true
    runAttempt(attempt, completion: completion)
  }

  private func runAttempt(
    _ attempt: @escaping OpenAttempt,
    completion: @escaping (Bool) -> Void
  ) {
    guard !finished, maximumAttempts > 0, attemptCount < maximumAttempts else {
      finish(false, completion: completion)
      return
    }

    attemptCount += 1
    var completionHandled = false
    attempt { [weak self] error in
      guard let self, !completionHandled, !finished else { return }
      completionHandled = true

      guard error != nil else {
        finish(true, completion: completion)
        return
      }
      guard attemptCount < maximumAttempts else {
        finish(false, completion: completion)
        return
      }

      scheduleRetry(retryDelay) { [weak self] in
        self?.runAttempt(attempt, completion: completion)
      }
    }
  }

  private func finish(_ succeeded: Bool, completion: (Bool) -> Void) {
    guard !finished else { return }
    finished = true
    completion(succeeded)
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
    guard CommandLine.arguments.count == 2 else {
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

    let registered = ExactApplicationRegistrationPolicy.wait(
      expectedBundleIdentifier: expectedBundleIdentifier,
      expectedCanonicalBundleURL: expectedCanonicalBundleURL,
      maximumChecks: maximumRegistrationChecks,
      snapshot: {
        NSRunningApplication.runningApplications(
          withBundleIdentifier: expectedBundleIdentifier
        ).map {
          RunningApplicationIdentity(
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

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.addsToRecentItems = false
    let coordinator = BoundedOpenCoordinator(
      maximumAttempts: maximumOpenAttempts,
      scheduleRetry: { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
      }
    )
    coordinator.start(
      attempt: { completion in
        NSWorkspace.shared.open(
          [url],
          withApplicationAt: lexicalApplicationURL,
          configuration: configuration
        ) { _, error in
          completion(error)
        }
      },
      completion: { succeeded in
        exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
      }
    )
    dispatchMain()
  }

  runHelper()
#endif
