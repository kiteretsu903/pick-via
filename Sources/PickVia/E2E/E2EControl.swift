#if PICKVIA_E2E_AUTOMATION
  import Foundation
  import PickViaCore

  enum E2EEnvironmentKey {
    static let targetID = "PICKVIA_E2E_TARGET_ID"
    static let bundleIdentifier = "PICKVIA_E2E_BUNDLE_ID"
    static let mode = "PICKVIA_E2E_MODE"
    static let sessionNonce = "PICKVIA_E2E_SESSION_NONCE"
    static let supportDirectory = "PICKVIA_E2E_SUPPORT_DIR"
    static let statusFIFO = "PICKVIA_E2E_STATUS_FIFO"
  }

  struct E2EControl: Equatable {
    let targetID: RouteTarget.ID
    let expectedBundleIdentifier: String
    let expectedMode: BrowserMode
    let sessionNonce: String
    let applicationSupportDirectory: URL
    let statusFIFO: URL

    static func load(environment: [String: String]) -> E2EControl? {
      guard
        let targetID = nonempty(environment[E2EEnvironmentKey.targetID], limit: 512),
        let bundleID = nonempty(
          environment[E2EEnvironmentKey.bundleIdentifier],
          limit: 255
        ),
        let rawMode = nonempty(environment[E2EEnvironmentKey.mode], limit: 16),
        let mode = BrowserMode(rawValue: rawMode),
        let nonce = nonempty(environment[E2EEnvironmentKey.sessionNonce], limit: 64),
        nonce.range(
          of: #"^[A-Za-z0-9_-]{16,64}$"#,
          options: .regularExpression
        ) != nil,
        let supportPath = nonempty(
          environment[E2EEnvironmentKey.supportDirectory],
          limit: 1_024
        ),
        let fifoPath = nonempty(environment[E2EEnvironmentKey.statusFIFO], limit: 1_024),
        supportPath.hasPrefix("/"),
        fifoPath.hasPrefix("/")
      else { return nil }

      let support = URL(fileURLWithPath: supportPath, isDirectory: true).standardizedFileURL
      let fifo = URL(fileURLWithPath: fifoPath).standardizedFileURL
      let supportName = support.lastPathComponent
      guard
        support.deletingLastPathComponent().path == "/private/tmp",
        supportName.hasPrefix("pickvia-e2e-"),
        supportName != "pickvia-e2e-",
        fifo.path.hasPrefix(support.path + "/")
      else { return nil }

      return E2EControl(
        targetID: targetID,
        expectedBundleIdentifier: bundleID,
        expectedMode: mode,
        sessionNonce: nonce,
        applicationSupportDirectory: support,
        statusFIFO: fifo
      )
    }
  }

  enum E2ESelectionOutcome: String, Equatable {
    case selected
    case controlMissing = "control-missing"
    case controlMalformed = "control-malformed"
    case targetMissing = "target-missing"
    case targetAmbiguous = "target-ambiguous"
    case targetDisabled = "target-disabled"
    case targetUnavailable = "target-unavailable"
    case targetBrowserMismatch = "target-browser-mismatch"
    case targetModeMismatch = "target-mode-mismatch"
    case nonWebRequest = "non-web-request"
    case launchError = "launch-error"
  }

  enum E2ETargetDecision: Equatable {
    case select(RouteTarget.ID)
    case reject(E2ESelectionOutcome)

    static func evaluate(
      control: E2EControl,
      requestKind: RouteKind,
      applications: [RoutedApplication],
      targets: [RouteTarget]
    ) -> E2ETargetDecision {
      guard requestKind == .web else { return .reject(.nonWebRequest) }
      let matches = targets.filter { $0.id == control.targetID }
      guard !matches.isEmpty else { return .reject(.targetMissing) }
      guard matches.count == 1 else { return .reject(.targetAmbiguous) }

      let target = matches[0]
      guard target.isEnabled else { return .reject(.targetDisabled) }
      guard target.availability == .available else { return .reject(.targetUnavailable) }
      guard
        let application = applications.first(where: { $0.id == target.applicationID }),
        application.bundleIdentifier == control.expectedBundleIdentifier,
        application.isAvailable(for: .web)
      else { return .reject(.targetBrowserMismatch) }
      guard
        case .browser(let options) = target.capability,
        options.mode == control.expectedMode
      else { return .reject(.targetModeMismatch) }

      return .select(target.id)
    }
  }

  private func nonempty(_ value: String?, limit: Int) -> String? {
    guard let value else { return nil }
    guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed == value, !trimmed.isEmpty, trimmed.utf8.count <= limit else { return nil }
    return trimmed
  }
#endif
