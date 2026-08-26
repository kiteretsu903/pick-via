#if PICKVIA_E2E_AUTOMATION
  import Darwin
  import Foundation
  import PickViaCore

  enum E2EEnvironmentKey {
    static let targetID = "PICKVIA_E2E_TARGET_ID"
    static let bundleIdentifier = "PICKVIA_E2E_BUNDLE_ID"
    static let mode = "PICKVIA_E2E_MODE"
    static let sessionNonce = "PICKVIA_E2E_SESSION_NONCE"
    static let requestNonce = "PICKVIA_E2E_REQUEST_NONCE"
    static let supportDirectory = "PICKVIA_E2E_SUPPORT_DIR"
    static let statusFIFO = "PICKVIA_E2E_STATUS_FIFO"
    static let provenanceFIFO = "PICKVIA_E2E_PROVENANCE_FIFO"
  }

  struct E2EControl: Equatable {
    let targetID: RouteTarget.ID
    let expectedBundleIdentifier: String
    let expectedMode: BrowserMode
    let sessionNonce: String
    let requestNonce: String
    let applicationSupportDirectory: URL
    let statusFIFO: URL
    let provenanceFIFO: URL

    var profileGrantManifest: URL {
      applicationSupportDirectory.appending(path: "profile-grant.json")
    }

    static func load(environment: [String: String]) -> E2EControl? {
      load(
        environment: environment,
        currentUID: getuid(),
        inspectSupportDirectory: inspectRealSupportDirectory
      )
    }

    static func load(
      environment: [String: String],
      currentUID: uid_t,
      inspectSupportDirectory: (URL) -> E2ESupportDirectoryInspection?
    ) -> E2EControl? {
      guard
        let targetID = nonempty(environment[E2EEnvironmentKey.targetID], limit: 512),
        let bundleID = nonempty(
          environment[E2EEnvironmentKey.bundleIdentifier],
          limit: 255
        ),
        let rawMode = nonempty(environment[E2EEnvironmentKey.mode], limit: 16),
        let mode = BrowserMode(rawValue: rawMode),
        let nonce = nonempty(environment[E2EEnvironmentKey.sessionNonce], limit: 64),
        isValidNonce(nonce),
        let requestNonce = nonempty(environment[E2EEnvironmentKey.requestNonce], limit: 64),
        isValidNonce(requestNonce),
        let supportPath = nonempty(
          environment[E2EEnvironmentKey.supportDirectory],
          limit: 1_024
        ),
        let fifoPath = nonempty(environment[E2EEnvironmentKey.statusFIFO], limit: 1_024),
        let provenancePath = nonempty(
          environment[E2EEnvironmentKey.provenanceFIFO],
          limit: 1_024
        ),
        let lexicalSupportPath = lexicallyStandardizedAbsolutePath(supportPath),
        lexicalSupportPath == supportPath,
        let lexicalFIFOPath = lexicallyStandardizedAbsolutePath(fifoPath),
        lexicalFIFOPath == fifoPath,
        let lexicalProvenancePath = lexicallyStandardizedAbsolutePath(provenancePath),
        lexicalProvenancePath == provenancePath
      else { return nil }

      let support = URL(fileURLWithPath: lexicalSupportPath, isDirectory: true)
      let fifo = URL(fileURLWithPath: lexicalFIFOPath)
      let provenanceFIFO = URL(fileURLWithPath: lexicalProvenancePath)
      let supportName = support.lastPathComponent
      guard
        support.deletingLastPathComponent().path == "/private/tmp",
        supportName.hasPrefix("pickvia-e2e-"),
        supportName != "pickvia-e2e-",
        fifo.deletingLastPathComponent().path == support.path,
        provenanceFIFO.deletingLastPathComponent().path == support.path,
        provenanceFIFO.path != fifo.path,
        let inspection = inspectSupportDirectory(support),
        inspection.isDirectory,
        !inspection.isSymbolicLink,
        inspection.ownerUID == currentUID,
        inspection.resolvedPath == support.path
      else { return nil }

      return E2EControl(
        targetID: targetID,
        expectedBundleIdentifier: bundleID,
        expectedMode: mode,
        sessionNonce: nonce,
        requestNonce: requestNonce,
        applicationSupportDirectory: support,
        statusFIFO: fifo,
        provenanceFIFO: provenanceFIFO
      )
    }
  }

  struct E2ESupportDirectoryInspection: Equatable {
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let ownerUID: uid_t
    let resolvedPath: String
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
    case targetShapeMismatch = "target-shape-mismatch"
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
      targets: [RouteTarget],
      descriptors: [BrowserDescriptor] = BrowserDescriptor.supported
    ) -> E2ETargetDecision {
      guard requestKind == .web else { return .reject(.nonWebRequest) }
      let matches = targets.filter { $0.id == control.targetID }
      guard !matches.isEmpty else { return .reject(.targetMissing) }
      guard matches.count == 1 else { return .reject(.targetAmbiguous) }

      let target = matches[0]
      guard target.isEnabled else { return .reject(.targetDisabled) }
      guard target.availability == .available else { return .reject(.targetUnavailable) }

      let linkedApplications = applications.filter { $0.id == target.applicationID }
      guard
        linkedApplications.count == 1,
        let application = linkedApplications.first,
        application.id == control.expectedBundleIdentifier,
        application.bundleIdentifier == control.expectedBundleIdentifier,
        application.isAvailable(for: .web),
        let descriptor = descriptors.first(where: {
          $0.bundleIdentifier == application.bundleIdentifier
        }),
        descriptor.hasCompatibleStrategies,
        descriptor.family == application.browserFamily
      else { return .reject(.targetBrowserMismatch) }
      guard
        case .browser(let options) = target.capability,
        options.mode == control.expectedMode
      else { return .reject(.targetModeMismatch) }
      guard
        target.applicationID == application.id,
        target.origin == .detected,
        isCanonical(target: target, options: options, descriptor: descriptor)
      else { return .reject(.targetShapeMismatch) }

      return .select(target.id)
    }

    private static func isCanonical(
      target: RouteTarget,
      options: BrowserTargetOptions,
      descriptor: BrowserDescriptor
    ) -> Bool {
      let hasProfileEvidence =
        options.profileIdentifier != nil
        || options.profileDisplayName != nil
        || options.profileIdentity != nil
        || options.profileLaunchPath != nil
      guard
        descriptor.supportsRoute(
          hasProfile: hasProfileEvidence,
          mode: options.mode
        )
      else { return false }
      guard hasProfileEvidence else {
        return target.id
          == BrowserCatalog.targetID(
            bundleIdentifier: descriptor.bundleIdentifier,
            profileIdentifier: nil,
            mode: options.mode
          )
      }

      guard
        let identifier = nonempty(options.profileIdentifier, limit: 512),
        identifier == options.profileIdentifier,
        let displayName = nonempty(options.profileDisplayName, limit: 512),
        displayName == options.profileDisplayName,
        let identity = nonempty(options.profileIdentity, limit: 512),
        identity == options.profileIdentity,
        target.id
          == BrowserCatalog.targetID(
            bundleIdentifier: descriptor.bundleIdentifier,
            profileIdentifier: identity,
            mode: options.mode
          )
      else { return false }

      switch descriptor.profileStrategy {
      case .none:
        return false
      case .chromium:
        return identifier == identity && options.profileLaunchPath == nil
      case .firefox:
        guard
          FirefoxProfileIdentity.isOpaqueIdentifier(identity),
          let launchPath = nonempty(options.profileLaunchPath, limit: 1_024),
          launchPath == options.profileLaunchPath,
          let lexicalLaunchPath = lexicallyStandardizedAbsolutePath(launchPath),
          lexicalLaunchPath == launchPath
        else { return false }
        let normalizedURL = URL(
          fileURLWithPath: launchPath,
          isDirectory: true
        ).standardizedFileURL
        return normalizedURL.path == launchPath
          && FirefoxProfileIdentity.identifier(for: normalizedURL) == identity
      case .safariShortcut:
        guard let launchPath = options.profileLaunchPath else { return true }
        return nonempty(launchPath, limit: 1_024) == launchPath
      }
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

  private func isValidNonce(_ value: String) -> Bool {
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

  private func lexicallyStandardizedAbsolutePath(_ path: String) -> String? {
    guard path.hasPrefix("/") else { return nil }
    var components: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
      switch component {
      case "", ".":
        continue
      case "..":
        guard !components.isEmpty else { return nil }
        components.removeLast()
      default:
        components.append(component)
      }
    }
    return "/" + components.joined(separator: "/")
  }

  private func inspectRealSupportDirectory(
    _ directory: URL
  ) -> E2ESupportDirectoryInspection? {
    var metadata = stat()
    let status = directory.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return lstat(path, &metadata)
    }
    guard status == 0 else { return nil }

    let resolvedPath = directory.withUnsafeFileSystemRepresentation { path -> String? in
      guard let path, let resolved = realpath(path, nil) else { return nil }
      defer { free(resolved) }
      return String(cString: resolved)
    }
    guard let resolvedPath else { return nil }

    let fileType = metadata.st_mode & mode_t(S_IFMT)
    return E2ESupportDirectoryInspection(
      isDirectory: fileType == mode_t(S_IFDIR),
      isSymbolicLink: fileType == mode_t(S_IFLNK),
      ownerUID: metadata.st_uid,
      resolvedPath: resolvedPath
    )
  }
#endif
