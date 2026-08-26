#if PICKVIA_E2E_AUTOMATION
  import Darwin
  import Foundation
  import PickViaCore
  import XCTest

  @testable import PickVia

  final class E2ELaunchProvenanceTests: XCTestCase {
    func testObservedRecordHasExactBoundedPrivacySafeSchema() throws {
      let line = try record(
        outcome: .launchObserved,
        processIdentifier: 4_321
      ).encodedLine()
      let object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(line.dropLast())) as? [String: Any]
      )

      XCTAssertEqual(
        Set(object.keys),
        [
          "session", "request", "target", "bundleIdentifier", "mode", "mechanism",
          "processIdentifier", "outcome",
        ]
      )
      XCTAssertEqual(object["session"] as? String, "session_0123456789")
      XCTAssertEqual(object["request"] as? String, "request_0123456789")
      XCTAssertEqual(object["target"] as? String, "com.microsoft.edgemac||normal")
      XCTAssertEqual(object["bundleIdentifier"] as? String, "com.microsoft.edgemac")
      XCTAssertEqual(object["mode"] as? String, "normal")
      XCTAssertEqual(object["mechanism"] as? String, "process")
      XCTAssertEqual(object["processIdentifier"] as? Int, 4_321)
      XCTAssertEqual(object["outcome"] as? String, "launch-observed")
      XCTAssertEqual(line.last, Character("\n").asciiValue)
      XCTAssertLessThanOrEqual(line.count, 512)
      let text = String(decoding: line, as: UTF8.self)
      for forbidden in ["https://", "arguments", "profile", "environment", "error", "label"] {
        XCTAssertFalse(text.contains(forbidden), forbidden)
      }
    }

    func testCanonicalProfileTargetWithInternalSpaceRemainsEncodable() throws {
      let line = try record(
        target: "com.google.Chrome|Profile 1|normal",
        outcome: .launchObserved,
        processIdentifier: 123
      ).encodedLine()

      XCTAssertTrue(String(decoding: line, as: UTF8.self).contains("Profile 1"))
    }

    func testUnprovenAndErrorRecordsOmitProcessIdentifier() throws {
      for outcome in [E2ELaunchProvenanceOutcome.launchUnproven, .launchError] {
        let line = try record(outcome: outcome, processIdentifier: nil).encodedLine()
        let object = try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(line.dropLast())) as? [String: Any]
        )
        XCTAssertFalse(object.keys.contains("processIdentifier"))
        XCTAssertEqual(object["outcome"] as? String, outcome.rawValue)
      }
    }

    func testRecordRejectsInvalidNoncePIDOutcomeConsistencyAndOversize() {
      let invalidNonces = [
        "short", "nonce.with.dots.1234", "nonce/with/slash123", "nonce_0123456789\n",
        String(repeating: "a", count: 65), "nonce_012345678é",
      ]
      for nonce in invalidNonces {
        XCTAssertThrowsError(
          try record(session: nonce, outcome: .launchObserved, processIdentifier: 1).encodedLine()
        )
        XCTAssertThrowsError(
          try record(request: nonce, outcome: .launchObserved, processIdentifier: 1).encodedLine()
        )
      }
      for pid in [Int32.min, -1, 0] {
        XCTAssertThrowsError(
          try record(outcome: .launchObserved, processIdentifier: pid).encodedLine()
        )
      }
      XCTAssertThrowsError(
        try record(outcome: .launchObserved, processIdentifier: nil).encodedLine()
      )
      XCTAssertThrowsError(
        try record(outcome: .launchUnproven, processIdentifier: 1).encodedLine()
      )
      XCTAssertThrowsError(
        try record(outcome: .launchError, processIdentifier: 1).encodedLine()
      )
      XCTAssertThrowsError(
        try record(
          target: String(repeating: "t", count: 600),
          outcome: .launchObserved,
          processIdentifier: 1
        ).encodedLine()
      )
    }

    func testRecordRejectsUnsafeClosedFields() {
      XCTAssertThrowsError(
        try record(mode: "incognito", outcome: .launchObserved, processIdentifier: 1).encodedLine()
      )
      XCTAssertThrowsError(
        try record(
          mechanism: "shell", outcome: .launchObserved, processIdentifier: 1
        ).encodedLine()
      )
      XCTAssertThrowsError(
        try record(
          bundleIdentifier: "com.example\nsecret",
          outcome: .launchObserved,
          processIdentifier: 1
        ).encodedLine()
      )
      XCTAssertThrowsError(
        try record(
          bundleIdentifier: "com.example secret",
          outcome: .launchObserved,
          processIdentifier: 1
        ).encodedLine()
      )
      XCTAssertThrowsError(
        try record(
          target: "https://example.test/private",
          outcome: .launchObserved,
          processIdentifier: 1
        ).encodedLine()
      )
    }

    func testWriterUsesPhysicalOwnedNonblockingFIFOAndRejectsDuplicateRequest() throws {
      try withTemporaryRoot { root in
        let fifo = root.appending(path: "provenance.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let reader = try ProvenanceFIFOReader(url: fifo)
        let writer = E2ELaunchProvenanceWriter(fifo: fifo)

        XCTAssertTrue(writer.write(record(outcome: .launchObserved, processIdentifier: 123)))
        XCTAssertFalse(writer.write(record(outcome: .launchObserved, processIdentifier: 123)))
        XCTAssertNotNil(reader.readLine(deadline: .now() + 1))
        XCTAssertNil(reader.readLine(deadline: .now() + .milliseconds(50)))
      }
    }

    func testWriterRejectsSymlinkWrongOwnerMissingReaderAndReplacement() throws {
      try withTemporaryRoot { root in
        let fifo = root.appending(path: "provenance.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let symlinkURL = root.appending(path: "provenance-link.fifo")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: fifo)

        XCTAssertFalse(
          E2ELaunchProvenanceWriter(fifo: symlinkURL)
            .write(record(outcome: .launchObserved, processIdentifier: 123))
        )
        XCTAssertFalse(
          E2ELaunchProvenanceWriter(fifo: fifo, currentUID: getuid() &+ 1)
            .write(record(outcome: .launchObserved, processIdentifier: 123))
        )
        let start = ContinuousClock.now
        XCTAssertFalse(
          E2ELaunchProvenanceWriter(fifo: fifo)
            .write(record(outcome: .launchObserved, processIdentifier: 123))
        )
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))

        let reader = try ProvenanceFIFOReader(url: fifo)
        let moved = root.appending(path: "moved.fifo")
        var replaced = false
        let writer = E2ELaunchProvenanceWriter(
          fifo: fifo,
          afterInspection: { inspected in
            XCTAssertEqual(inspected, fifo)
            guard rename(fifo.path, moved.path) == 0 else { return }
            guard symlink(moved.path, fifo.path) == 0 else { return }
            replaced = true
          }
        )
        XCTAssertFalse(writer.write(record(outcome: .launchObserved, processIdentifier: 124)))
        XCTAssertTrue(replaced)
        XCTAssertNil(reader.readLine(deadline: .now() + .milliseconds(50)))
      }
    }

    private func record(
      session: String = "session_0123456789",
      request: String = "request_0123456789",
      target: String = "com.microsoft.edgemac||normal",
      bundleIdentifier: String = "com.microsoft.edgemac",
      mode: String = "normal",
      mechanism: String = "process",
      outcome: E2ELaunchProvenanceOutcome,
      processIdentifier: Int32?
    ) -> E2ELaunchProvenanceRecord {
      E2ELaunchProvenanceRecord(
        session: session,
        request: request,
        target: target,
        bundleIdentifier: bundleIdentifier,
        mode: mode,
        mechanism: mechanism,
        processIdentifier: processIdentifier,
        outcome: outcome
      )
    }

    private func withTemporaryRoot(_ body: (URL) throws -> Void) throws {
      let root = URL(
        fileURLWithPath: "/private/tmp/pickvia-e2e-provenance-\(UUID().uuidString)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      defer { try? FileManager.default.removeItem(at: root) }
      try body(root)
    }
  }

  private final class ProvenanceFIFOReader {
    private let descriptor: Int32

    init(url: URL) throws {
      descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
      guard descriptor >= 0 else { throw POSIXProvenanceTestError(code: errno) }
    }

    deinit { close(descriptor) }

    func readLine(deadline: DispatchTime) -> Data? {
      var received = Data()
      var buffer = [UInt8](repeating: 0, count: 512)
      while DispatchTime.now() < deadline {
        let count = read(descriptor, &buffer, buffer.count)
        if count > 0 {
          received.append(buffer, count: count)
          if received.last == Character("\n").asciiValue { return received }
        } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
          return nil
        }
        usleep(1_000)
      }
      return nil
    }
  }

  private struct POSIXProvenanceTestError: Error { let code: Int32 }
#endif
