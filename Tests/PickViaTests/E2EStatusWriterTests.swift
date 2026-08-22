#if PICKVIA_E2E_AUTOMATION
  import Darwin
  import Foundation
  import XCTest

  @testable import PickVia

  final class E2EStatusWriterTests: XCTestCase {
    func testWriterEmitsExactlySortedSessionAndClosedOutcome() throws {
      try withTemporaryRoot { root in
        let fifo = root.appending(path: "status.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let reader = try NonblockingFIFOReader(url: fifo)

        XCTAssertTrue(
          E2EStatusWriter().write(
            .selected,
            sessionNonce: "session_0123456789",
            to: fifo
          )
        )

        let line = try XCTUnwrap(reader.readLine(deadline: .now() + 1))
        XCTAssertEqual(
          String(decoding: line, as: UTF8.self),
          #"{"outcome":"selected","session":"session_0123456789"}"# + "\n"
        )
        let object = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(line.dropLast())) as? [String: String]
        )
        XCTAssertEqual(Set(object.keys), ["session", "outcome"])
        XCTAssertEqual(object["session"], "session_0123456789")
        XCTAssertEqual(object["outcome"], "selected")
      }
    }

    func testWriterRejectsRegularFileSymlinksAndMissingPath() throws {
      try withTemporaryRoot { root in
        let regular = root.appending(path: "regular")
        XCTAssertTrue(FileManager.default.createFile(atPath: regular.path, contents: Data()))
        let regularSymlink = root.appending(path: "regular-symlink")
        try FileManager.default.createSymbolicLink(
          at: regularSymlink,
          withDestinationURL: regular
        )
        let fifo = root.appending(path: "status.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let fifoSymlink = root.appending(path: "fifo-symlink")
        try FileManager.default.createSymbolicLink(at: fifoSymlink, withDestinationURL: fifo)

        let writer = E2EStatusWriter()
        for invalid in [
          regular,
          regularSymlink,
          fifoSymlink,
          root.appending(path: "missing"),
        ] {
          XCTAssertFalse(
            writer.write(.selected, sessionNonce: "session_0123456789", to: invalid),
            "unexpectedly wrote to \(invalid.path)"
          )
        }
      }
    }

    func testWriterRejectsFIFOOwnedByAnotherUID() throws {
      try withTemporaryRoot { root in
        let fifo = root.appending(path: "status.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let reader = try NonblockingFIFOReader(url: fifo)
        withExtendedLifetime(reader) {
          XCTAssertFalse(
            E2EStatusWriter(currentUID: getuid() &+ 1).write(
              .selected,
              sessionNonce: "session_0123456789",
              to: fifo
            )
          )
        }
      }
    }

    func testMissingReaderFailsImmediatelyWithoutOpeningOrHanging() throws {
      try withTemporaryRoot { root in
        let fifo = root.appending(path: "unread.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let start = ContinuousClock.now
        XCTAssertFalse(
          E2EStatusWriter().write(
            .selected,
            sessionNonce: "session_0123456789",
            to: fifo
          )
        )
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
      }
    }

    func testEveryOutcomeContainsNoURLOrArbitraryTargetText() throws {
      let outcomes: [E2ESelectionOutcome] = [
        .selected,
        .controlMissing,
        .controlMalformed,
        .targetMissing,
        .targetAmbiguous,
        .targetDisabled,
        .targetUnavailable,
        .targetBrowserMismatch,
        .targetModeMismatch,
        .targetShapeMismatch,
        .nonWebRequest,
        .launchError,
      ]

      for outcome in outcomes {
        let line = try E2EStatusRecord(
          session: "session_0123456789",
          outcome: outcome
        ).encodedLine()
        let text = try XCTUnwrap(String(data: line, encoding: .utf8))
        XCTAssertFalse(text.contains("://"))
        XCTAssertFalse(text.contains("target-id"))
        XCTAssertEqual(line.last, Character("\n").asciiValue)

        let object = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(line.dropLast())) as? [String: String]
        )
        XCTAssertEqual(Set(object.keys), ["session", "outcome"])
        XCTAssertEqual(object["outcome"], outcome.rawValue)
      }
    }

    func testRecordAndWriterRejectArbitraryOrMalformedSessionText() throws {
      let invalidSessions = [
        "https://example.test/private",
        "target||id||is||not||a||session",
        "session_01234567\nsecret",
        String(repeating: "a", count: 65),
        "too_short",
      ]

      for session in invalidSessions {
        XCTAssertThrowsError(
          try E2EStatusRecord(session: session, outcome: .selected).encodedLine()
        )
      }

      try withTemporaryRoot { root in
        let fifo = root.appending(path: "status.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let reader = try NonblockingFIFOReader(url: fifo)
        withExtendedLifetime(reader) {
          for session in invalidSessions {
            XCTAssertFalse(E2EStatusWriter().write(.selected, sessionNonce: session, to: fifo))
          }
        }
      }
    }

    private func withTemporaryRoot(
      _ body: (URL) throws -> Void
    ) throws {
      let root = URL(
        fileURLWithPath: "/private/tmp/pickvia-e2e-status-\(UUID().uuidString)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      try body(root)
    }
  }

  private final class NonblockingFIFOReader {
    private let fileDescriptor: Int32

    init(url: URL) throws {
      fileDescriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
      guard fileDescriptor >= 0 else {
        throw POSIXTestError(operation: "open", code: errno)
      }
    }

    deinit {
      close(fileDescriptor)
    }

    func readLine(deadline: DispatchTime) -> Data? {
      var received = Data()
      var buffer = [UInt8](repeating: 0, count: 512)

      while DispatchTime.now() < deadline {
        let count = read(fileDescriptor, &buffer, buffer.count)
        if count > 0 {
          received.append(buffer, count: count)
          if received.last == Character("\n").asciiValue {
            return received
          }
        } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
          return nil
        }
        usleep(1_000)
      }
      return nil
    }
  }

  private struct POSIXTestError: Error {
    let operation: String
    let code: Int32
  }
#endif
