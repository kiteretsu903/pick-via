#if PICKVIA_E2E_AUTOMATION
  import Darwin
  import Foundation

  extension E2ESelectionOutcome: Codable {}

  struct E2EStatusRecord: Codable, Equatable {
    let session: String
    let outcome: E2ESelectionOutcome

    func encodedLine() throws -> Data {
      guard Self.isValidSessionNonce(session) else {
        throw EncodingError.invalidSessionNonce
      }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      var data = try encoder.encode(self)
      data.append(0x0A)
      guard data.count <= E2EStatusWriter.maximumRecordBytes else {
        throw EncodingError.recordTooLarge
      }
      return data
    }

    private static func isValidSessionNonce(_ value: String) -> Bool {
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

    enum EncodingError: Error {
      case invalidSessionNonce
      case recordTooLarge
    }
  }

  protocol E2EStatusWriting {
    func write(
      _ outcome: E2ESelectionOutcome,
      sessionNonce: String,
      to fifo: URL
    ) -> Bool
  }

  struct E2EStatusWriter: E2EStatusWriting {
    // POSIX guarantees atomic FIFO writes through at least this size.
    static let maximumRecordBytes = 512

    private let currentUID: uid_t

    init(currentUID: uid_t = getuid()) {
      self.currentUID = currentUID
    }

    func write(
      _ outcome: E2ESelectionOutcome,
      sessionNonce: String,
      to fifo: URL
    ) -> Bool {
      guard fifo.isFileURL else { return false }
      guard
        let record = try? E2EStatusRecord(
          session: sessionNonce,
          outcome: outcome
        ).encodedLine()
      else { return false }

      var inspected = stat()
      let inspectionStatus = fifo.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return lstat(path, &inspected)
      }
      guard inspectionStatus == 0, isOwnedFIFO(inspected) else { return false }

      let descriptor = fifo.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
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

      let written = record.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return -1 }
        return Darwin.write(descriptor, baseAddress, bytes.count)
      }
      return written == record.count
    }

    private func isOwnedFIFO(_ metadata: stat) -> Bool {
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO)
        && metadata.st_uid == currentUID
    }
  }
#endif
