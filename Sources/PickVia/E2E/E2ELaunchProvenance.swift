#if PICKVIA_E2E_AUTOMATION
  import Darwin
  import Foundation
  import PickViaCore

  enum E2ELaunchProvenanceOutcome: String, Codable, Equatable {
    case launchObserved = "launch-observed"
    case launchUnproven = "launch-unproven"
    case launchError = "launch-error"
  }

  struct E2ELaunchProvenanceRecord: Codable, Equatable {
    let session: String
    let request: String
    let target: String
    let bundleIdentifier: String
    let mode: String
    let mechanism: String
    let processIdentifier: Int32?
    let outcome: E2ELaunchProvenanceOutcome

    func encodedLine() throws -> Data {
      guard Self.isValidNonce(session), Self.isValidNonce(request) else {
        throw ValidationError.invalidNonce
      }
      guard
        Self.isSafeTarget(target, maximumBytes: 512),
        !target.contains("://"),
        Self.isSafeBundleIdentifier(bundleIdentifier),
        BrowserMode(rawValue: mode) != nil,
        ["process", "workspace", "duckduckgo"].contains(mechanism)
      else { throw ValidationError.invalidField }
      switch outcome {
      case .launchObserved:
        guard let processIdentifier, processIdentifier > 0 else {
          throw ValidationError.inconsistentOutcome
        }
      case .launchUnproven, .launchError:
        guard processIdentifier == nil else {
          throw ValidationError.inconsistentOutcome
        }
      }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      var data = try encoder.encode(self)
      data.append(0x0A)
      guard data.count <= E2ELaunchProvenanceWriter.maximumRecordBytes else {
        throw ValidationError.recordTooLarge
      }
      return data
    }

    private static func isValidNonce(_ value: String) -> Bool {
      guard (16...64).contains(value.utf8.count), value.unicodeScalars.count == value.utf8.count
      else { return false }
      return value.utf8.allSatisfy { byte in
        switch byte {
        case 45, 48...57, 65...90, 95, 97...122:
          true
        default:
          false
        }
      }
    }

    private static func isSafeTarget(_ value: String, maximumBytes: Int) -> Bool {
      guard
        !value.isEmpty,
        value.utf8.count <= maximumBytes,
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      else { return false }
      return !value.unicodeScalars.contains { scalar in
        CharacterSet.controlCharacters.contains(scalar)
      }
    }

    private static func isSafeBundleIdentifier(_ value: String) -> Bool {
      guard !value.isEmpty, value.utf8.count <= 255 else { return false }
      return value.utf8.allSatisfy { byte in
        switch byte {
        case 45, 46, 48...57, 65...90, 95, 97...122:
          true
        default:
          false
        }
      }
    }

    enum ValidationError: Error {
      case invalidNonce
      case invalidField
      case inconsistentOutcome
      case recordTooLarge
    }
  }

  final class E2ELaunchProvenanceWriter:
    BrowserLaunchProvenanceSinking, @unchecked Sendable
  {
    static let maximumRecordBytes = 512

    private let fifo: URL
    private let currentUID: uid_t
    private let afterInspection: (URL) -> Void
    private let lock = NSLock()
    private var attemptedRequests: Set<String> = []

    init(
      fifo: URL,
      currentUID: uid_t = getuid(),
      afterInspection: @escaping (URL) -> Void = { _ in }
    ) {
      self.fifo = fifo
      self.currentUID = currentUID
      self.afterInspection = afterInspection
    }

    func record(
      _ event: BrowserLaunchProvenanceEvent,
      context: BrowserLaunchProvenanceContext
    ) -> Bool {
      let mechanism: BrowserLaunchMechanism
      let outcome: E2ELaunchProvenanceOutcome
      let processIdentifier: Int32?
      switch event {
      case .observed(let observation):
        mechanism = observation.mechanism
        outcome = .launchObserved
        processIdentifier = observation.processIdentifier
      case .launchUnproven(let value):
        mechanism = value
        outcome = .launchUnproven
        processIdentifier = nil
      case .launchError(let value):
        mechanism = value
        outcome = .launchError
        processIdentifier = nil
      }
      return write(
        E2ELaunchProvenanceRecord(
          session: context.sessionNonce,
          request: context.requestNonce,
          target: context.targetID,
          bundleIdentifier: context.expectedBundleIdentifier,
          mode: context.mode.rawValue,
          mechanism: Self.rawMechanism(mechanism),
          processIdentifier: processIdentifier,
          outcome: outcome
        )
      )
    }

    func write(_ record: E2ELaunchProvenanceRecord) -> Bool {
      lock.lock()
      guard attemptedRequests.insert(record.request).inserted else {
        lock.unlock()
        return false
      }
      lock.unlock()

      guard fifo.isFileURL, let line = try? record.encodedLine() else { return false }
      var inspected = stat()
      let inspectionStatus = fifo.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return lstat(path, &inspected)
      }
      guard inspectionStatus == 0, isOwnedFIFO(inspected) else { return false }
      afterInspection(fifo)

      let descriptor = fifo.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)
      }
      guard descriptor >= 0 else { return false }
      defer { close(descriptor) }

      var opened = stat()
      guard
        fstat(descriptor, &opened) == 0,
        isOwnedFIFO(opened),
        opened.st_dev == inspected.st_dev,
        opened.st_ino == inspected.st_ino,
        fcntl(descriptor, F_GETFL) & O_NONBLOCK != 0,
        fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0,
        fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0
      else { return false }

      let written = line.withUnsafeBytes { bytes in
        guard let address = bytes.baseAddress else { return -1 }
        return Darwin.write(descriptor, address, bytes.count)
      }
      return written == line.count
    }

    private func isOwnedFIFO(_ metadata: stat) -> Bool {
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO)
        && metadata.st_uid == currentUID
    }

    private static func rawMechanism(_ mechanism: BrowserLaunchMechanism) -> String {
      switch mechanism {
      case .process: "process"
      case .workspace: "workspace"
      case .duckDuckGo: "duckduckgo"
      }
    }
  }
#endif
