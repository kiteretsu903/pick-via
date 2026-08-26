#if PICKVIA_E2E_AUTOMATION
  import Darwin
  import Foundation
  import PickViaCore

  struct E2EProfileGrantManifest: Codable, Equatable {
    let schemaVersion: Int
    let bundleIdentifier: String
    let strategy: String
    let relativeRoot: String
  }

  enum E2EProfileGrantError: Error, Equatable {
    case invalidManifest
    case descriptorMismatch
    case invalidRoot
    case invalidProfiles
    case grantUnavailable
  }

  struct E2EValidatedProfileGrant: Equatable {
    let descriptor: BrowserDescriptor
    let supportRoot: URL
    let root: URL
    let profileIdentifier: String
    let profileDirectory: URL
    fileprivate let relativeRootComponents: [String]
    fileprivate let supportIdentity: E2EFileIdentity
    fileprivate let rootIdentity: E2EFileIdentity
    fileprivate let profileIdentity: E2EFileIdentity
    fileprivate let ownerUID: uid_t

    func matchesChromiumTarget(
      control: E2EControl,
      descriptor candidateDescriptor: BrowserDescriptor,
      profileIdentifier candidateIdentifier: String,
      profileDirectory candidateDirectory: URL
    ) -> Bool {
      guard
        candidateDescriptor == descriptor,
        control.expectedBundleIdentifier == descriptor.bundleIdentifier,
        control.applicationSupportDirectory.path == supportRoot.path,
        candidateIdentifier == profileIdentifier,
        candidateDirectory.path == profileDirectory.path,
        candidateDirectory.lastPathComponent == candidateIdentifier,
        candidateDirectory.deletingLastPathComponent().path == root.path,
        root.appending(path: candidateIdentifier, directoryHint: .isDirectory).path
          == candidateDirectory.path,
        case .chromium = descriptor.profileStrategy
      else { return false }

      do {
        let supportDescriptor = try E2EProfileGrantInstaller.openDirectory(supportRoot)
        defer { close(supportDescriptor) }
        let currentSupportIdentity = try E2EProfileGrantInstaller.validatedDirectoryIdentity(
          descriptor: supportDescriptor,
          publicURL: supportRoot,
          ownerUID: ownerUID,
          requiredDevice: supportIdentity.device,
          requiresRestrictedMode: true
        )
        guard currentSupportIdentity.hasSameNodeOwnerAndMode(as: supportIdentity) else {
          return false
        }

        let rootDescriptor = try E2EProfileGrantInstaller.openDirectory(
          components: relativeRootComponents,
          beneath: supportDescriptor
        )
        defer { close(rootDescriptor) }
        _ = try E2EProfileGrantInstaller.validatedDirectoryIdentity(
          descriptor: rootDescriptor,
          publicURL: root,
          ownerUID: ownerUID,
          requiredDevice: supportIdentity.device,
          requiresRestrictedMode: true,
          expectedIdentity: rootIdentity
        )

        let profileDescriptor = try E2EProfileGrantInstaller.openDirectory(
          components: [candidateIdentifier],
          beneath: rootDescriptor
        )
        defer { close(profileDescriptor) }
        _ = try E2EProfileGrantInstaller.validatedDirectoryIdentity(
          descriptor: profileDescriptor,
          publicURL: candidateDirectory,
          ownerUID: ownerUID,
          requiredDevice: rootIdentity.device,
          requiresRestrictedMode: true,
          expectedIdentity: profileIdentity
        )
        return true
      } catch {
        return false
      }
    }
  }

  private struct E2EValidatedSyntheticProfile {
    let identifier: String
    let directory: URL
    let identity: E2EFileIdentity
  }

  enum E2EProfileGrantInstaller {
    private static let schemaVersion = 1
    private static let syntheticProfileName = "PickVia E2E"
    private static let maximumManifestBytes = 4_096
    private static let maximumMarkerBytes = 1_048_576

    static func installIfPresent(
      control: E2EControl,
      descriptors: [BrowserDescriptor],
      coordinator: any ProfileAccessManaging,
      currentUID: uid_t = getuid()
    ) throws -> E2EValidatedProfileGrant? {
      let supportDescriptor = try openDirectory(control.applicationSupportDirectory)
      defer { close(supportDescriptor) }
      let supportIdentity = try validatedDirectoryIdentity(
        descriptor: supportDescriptor,
        publicURL: control.applicationSupportDirectory,
        ownerUID: currentUID,
        requiredDevice: nil,
        requiresRestrictedMode: true
      )

      guard manifestEntryExists(control.profileGrantManifest, supportDescriptor: supportDescriptor)
      else { return nil }
      let manifestData = try readRestrictedRegularFile(
        named: control.profileGrantManifest.lastPathComponent,
        beneath: supportDescriptor,
        ownerUID: currentUID,
        requiredDevice: supportIdentity.device,
        maximumBytes: maximumManifestBytes
      )
      let manifest = try decodeManifest(manifestData)
      guard
        manifest.schemaVersion == schemaVersion,
        manifest.bundleIdentifier == control.expectedBundleIdentifier
      else { throw E2EProfileGrantError.descriptorMismatch }

      let matchingDescriptors = descriptors.filter {
        $0.bundleIdentifier == manifest.bundleIdentifier
      }
      guard
        matchingDescriptors.count == 1,
        let descriptor = matchingDescriptors.first,
        descriptor.hasCompatibleStrategies,
        strategyName(descriptor.profileStrategy) == manifest.strategy,
        descriptor.requiredProfileMarker != nil
      else { throw E2EProfileGrantError.descriptorMismatch }

      let components = try relativePathComponents(manifest.relativeRoot)
      let rootURL = components.reduce(control.applicationSupportDirectory) { partial, component in
        partial.appending(path: component, directoryHint: .isDirectory)
      }
      let rootDescriptor = try openDirectory(
        components: components,
        beneath: supportDescriptor
      )
      defer { close(rootDescriptor) }
      let rootIdentity = try validatedDirectoryIdentity(
        descriptor: rootDescriptor,
        publicURL: rootURL,
        ownerUID: currentUID,
        requiredDevice: supportIdentity.device,
        requiresRestrictedMode: true
      )

      let profile = try validateSyntheticProfile(
        descriptor: descriptor,
        rootURL: rootURL,
        rootDescriptor: rootDescriptor,
        rootIdentity: rootIdentity,
        ownerUID: currentUID
      )

      let persistence = try coordinator.installGrant(
        root: rootURL,
        for: descriptor.bundleIdentifier
      )
      guard persistence == .persistent || persistence == .currentSessionOnly else {
        throw E2EProfileGrantError.grantUnavailable
      }
      let access = coordinator.beginAccess(for: descriptor.bundleIdentifier)
      guard access.state == .granted, let lease = access.lease else {
        throw E2EProfileGrantError.grantUnavailable
      }
      defer { lease.end() }
      let expectedProvenance: ProfileRootAccessProvenance =
        persistence == .persistent ? .persistentBookmark : .currentSessionGrant
      guard access.provenance == expectedProvenance else {
        throw E2EProfileGrantError.grantUnavailable
      }
      guard lease.root.standardizedFileURL == rootURL.standardizedFileURL else {
        throw E2EProfileGrantError.grantUnavailable
      }
      _ = try validatedDirectoryIdentity(
        descriptor: rootDescriptor,
        publicURL: lease.root,
        ownerUID: currentUID,
        requiredDevice: rootIdentity.device,
        requiresRestrictedMode: true,
        expectedIdentity: rootIdentity
      )
      return E2EValidatedProfileGrant(
        descriptor: descriptor,
        supportRoot: control.applicationSupportDirectory,
        root: rootURL,
        profileIdentifier: profile.identifier,
        profileDirectory: profile.directory,
        relativeRootComponents: components,
        supportIdentity: supportIdentity,
        rootIdentity: rootIdentity,
        profileIdentity: profile.identity,
        ownerUID: currentUID
      )
    }

    private static func manifestEntryExists(
      _ manifestURL: URL,
      supportDescriptor: Int32
    ) -> Bool {
      var metadata = stat()
      let result = manifestURL.lastPathComponent.withCString { name in
        fstatat(supportDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW)
      }
      if result == 0 { return true }
      return errno != ENOENT
    }

    private static func decodeManifest(_ data: Data) throws -> E2EProfileGrantManifest {
      try E2EProfileGrantJSONDecoder.decode(data)
    }

    private static func strategyName(_ strategy: BrowserProfileStrategy) -> String? {
      switch strategy {
      case .chromium:
        "chromium"
      case .firefox:
        "firefox"
      case .none, .safariShortcut:
        nil
      }
    }

    private static func relativePathComponents(_ path: String) throws -> [String] {
      guard
        !path.isEmpty,
        path.utf8.count <= 1_024,
        !path.hasPrefix("/"),
        !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { throw E2EProfileGrantError.invalidRoot }
      let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
      guard
        !components.isEmpty,
        components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
        components.joined(separator: "/") == path
      else { throw E2EProfileGrantError.invalidRoot }
      return components
    }

    private static func validateSyntheticProfile(
      descriptor: BrowserDescriptor,
      rootURL: URL,
      rootDescriptor: Int32,
      rootIdentity: E2EFileIdentity,
      ownerUID: uid_t
    ) throws -> E2EValidatedSyntheticProfile {
      guard let marker = descriptor.requiredProfileMarker else {
        throw E2EProfileGrantError.descriptorMismatch
      }
      let markerData = try readRestrictedRegularFile(
        named: marker,
        beneath: rootDescriptor,
        ownerUID: ownerUID,
        requiredDevice: rootIdentity.device,
        maximumBytes: maximumMarkerBytes
      )

      let profiles: [DiscoveredProfile]
      let rawFirefoxProfilePath: String?
      do {
        switch descriptor.profileStrategy {
        case .chromium:
          try validateRawChromiumProfileCardinality(markerData)
          profiles = try ChromiumProfileParser.parse(data: markerData)
          rawFirefoxProfilePath = nil
        case .firefox:
          guard let text = String(data: markerData, encoding: .utf8) else {
            throw E2EProfileGrantError.invalidProfiles
          }
          profiles = try FirefoxProfileParser.parse(text: text, baseDirectory: rootURL)
          rawFirefoxProfilePath = try exactFirefoxProfilePath(text)
        case .none, .safariShortcut:
          throw E2EProfileGrantError.descriptorMismatch
        }
      } catch let error as E2EProfileGrantError {
        throw error
      } catch {
        throw E2EProfileGrantError.invalidProfiles
      }

      guard profiles.count == 1,
        let profile = profiles.first,
        profile.displayName == syntheticProfileName
      else { throw E2EProfileGrantError.invalidProfiles }

      let childName: String
      switch descriptor.profileStrategy {
      case .chromium:
        childName = profile.identifier
      case .firefox:
        guard let directoryURL = profile.directoryURL else {
          throw E2EProfileGrantError.invalidProfiles
        }
        childName = directoryURL.lastPathComponent
        guard
          rawFirefoxProfilePath == childName,
          directoryURL.deletingLastPathComponent().standardizedFileURL
            == rootURL.standardizedFileURL,
          rootURL.appending(path: childName, directoryHint: .isDirectory).standardizedFileURL
            == directoryURL.standardizedFileURL
        else { throw E2EProfileGrantError.invalidProfiles }
      case .none, .safariShortcut:
        throw E2EProfileGrantError.descriptorMismatch
      }
      guard
        !childName.isEmpty,
        childName != ".",
        childName != "..",
        !childName.contains("/")
      else { throw E2EProfileGrantError.invalidProfiles }

      let childDescriptor: Int32
      do {
        childDescriptor = try openDirectory(components: [childName], beneath: rootDescriptor)
      } catch {
        throw E2EProfileGrantError.invalidProfiles
      }
      defer { close(childDescriptor) }
      let childURL = rootURL.appending(path: childName, directoryHint: .isDirectory)
      do {
        let identity = try validatedDirectoryIdentity(
          descriptor: childDescriptor,
          publicURL: childURL,
          ownerUID: ownerUID,
          requiredDevice: rootIdentity.device,
          requiresRestrictedMode: true
        )
        return E2EValidatedSyntheticProfile(
          identifier: childName,
          directory: childURL,
          identity: identity
        )
      } catch {
        throw E2EProfileGrantError.invalidProfiles
      }
    }

    private static func validateRawChromiumProfileCardinality(_ data: Data) throws {
      let value: Any
      do {
        value = try JSONSerialization.jsonObject(with: data)
      } catch {
        throw E2EProfileGrantError.invalidProfiles
      }
      guard
        let root = value as? [String: Any],
        let profile = root["profile"] as? [String: Any],
        let infoCache = profile["info_cache"] as? [String: Any],
        infoCache.count == 1
      else { throw E2EProfileGrantError.invalidProfiles }
    }

    private static func exactFirefoxProfilePath(_ text: String) throws -> String {
      let lines = text.components(separatedBy: .newlines).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      let paths = lines.compactMap { line -> String? in
        guard line.hasPrefix("Path=") else { return nil }
        return String(line.dropFirst("Path=".count))
      }
      guard
        paths.count == 1,
        lines.filter({ $0 == "IsRelative=1" }).count == 1,
        let path = paths.first,
        !path.isEmpty,
        path != ".",
        path != "..",
        !path.contains("/")
      else { throw E2EProfileGrantError.invalidProfiles }
      return path
    }

    fileprivate static func openDirectory(_ url: URL) throws -> Int32 {
      let descriptor = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard descriptor >= 0 else { throw E2EProfileGrantError.invalidRoot }
      return descriptor
    }

    fileprivate static func openDirectory(
      components: [String],
      beneath parentDescriptor: Int32
    ) throws -> Int32 {
      var current = dup(parentDescriptor)
      guard current >= 0 else { throw E2EProfileGrantError.invalidRoot }
      do {
        for component in components {
          let next = component.withCString { name in
            openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
          }
          guard next >= 0 else { throw E2EProfileGrantError.invalidRoot }
          close(current)
          current = next
        }
        return current
      } catch {
        close(current)
        throw error
      }
    }

    fileprivate static func validatedDirectoryIdentity(
      descriptor: Int32,
      publicURL: URL,
      ownerUID: uid_t,
      requiredDevice: dev_t?,
      requiresRestrictedMode: Bool,
      expectedIdentity: E2EFileIdentity? = nil
    ) throws -> E2EFileIdentity {
      var opened = stat()
      guard fstat(descriptor, &opened) == 0 else {
        throw E2EProfileGrantError.invalidRoot
      }
      var named = stat()
      let namedStatus = publicURL.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return lstat(path, &named)
      }
      let identity = E2EFileIdentity(opened)
      guard
        namedStatus == 0,
        (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
        (named.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
        E2EFileIdentity(named) == identity,
        opened.st_uid == ownerUID,
        requiredDevice == nil || opened.st_dev == requiredDevice,
        !requiresRestrictedMode || (opened.st_mode & 0o077) == 0,
        expectedIdentity == nil || identity == expectedIdentity,
        resolvedPath(publicURL) == publicURL.path
      else { throw E2EProfileGrantError.invalidRoot }
      return identity
    }

    private static func readRestrictedRegularFile(
      named name: String,
      beneath parentDescriptor: Int32,
      ownerUID: uid_t,
      requiredDevice: dev_t,
      maximumBytes: Int
    ) throws -> Data {
      let descriptor = name.withCString { pointer in
        openat(parentDescriptor, pointer, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard descriptor >= 0 else { throw E2EProfileGrantError.invalidManifest }
      defer { close(descriptor) }

      var before = stat()
      var namedBefore = stat()
      guard
        fstat(descriptor, &before) == 0,
        name.withCString({ pointer in
          fstatat(parentDescriptor, pointer, &namedBefore, AT_SYMLINK_NOFOLLOW)
        }) == 0
      else { throw E2EProfileGrantError.invalidManifest }
      let identity = E2EFileIdentity(before)
      guard
        (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        (namedBefore.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        E2EFileIdentity(namedBefore) == identity,
        before.st_uid == ownerUID,
        before.st_dev == requiredDevice,
        (before.st_mode & 0o077) == 0,
        before.st_nlink == 1,
        before.st_size >= 0,
        before.st_size <= maximumBytes
      else { throw E2EProfileGrantError.invalidManifest }

      let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
      let data: Data
      do {
        data = try handle.readToEnd() ?? Data()
      } catch {
        throw E2EProfileGrantError.invalidManifest
      }
      var after = stat()
      var namedAfter = stat()
      guard
        data.count == before.st_size,
        fstat(descriptor, &after) == 0,
        name.withCString({ pointer in
          fstatat(parentDescriptor, pointer, &namedAfter, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        E2EFileIdentity(after) == identity,
        E2EFileIdentity(namedAfter) == identity
      else { throw E2EProfileGrantError.invalidManifest }
      return data
    }

    private static func resolvedPath(_ url: URL) -> String? {
      url.withUnsafeFileSystemRepresentation { path -> String? in
        guard let path, let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
      }
    }
  }

  private struct E2EProfileGrantJSONDecoder {
    private let bytes: [UInt8]
    private var index = 0

    static func decode(_ data: Data) throws -> E2EProfileGrantManifest {
      var decoder = E2EProfileGrantJSONDecoder(bytes: Array(data))
      return try decoder.decodeManifest()
    }

    private mutating func decodeManifest() throws -> E2EProfileGrantManifest {
      skipWhitespace()
      try consume(0x7B)
      skipWhitespace()

      var seen = Set<String>()
      var schemaVersion: Int?
      var bundleIdentifier: String?
      var strategy: String?
      var relativeRoot: String?
      guard !consumeIfPresent(0x7D) else {
        throw E2EProfileGrantError.invalidManifest
      }

      while true {
        let key = try decodeString()
        guard seen.insert(key).inserted else {
          throw E2EProfileGrantError.invalidManifest
        }
        skipWhitespace()
        try consume(0x3A)
        skipWhitespace()
        switch key {
        case "schemaVersion":
          schemaVersion = try decodeInteger()
        case "bundleIdentifier":
          bundleIdentifier = try decodeString()
        case "strategy":
          strategy = try decodeString()
        case "relativeRoot":
          relativeRoot = try decodeString()
        default:
          throw E2EProfileGrantError.invalidManifest
        }
        skipWhitespace()
        if consumeIfPresent(0x2C) {
          skipWhitespace()
          continue
        }
        try consume(0x7D)
        break
      }

      skipWhitespace()
      guard
        index == bytes.count,
        seen
          == Set(["schemaVersion", "bundleIdentifier", "strategy", "relativeRoot"]),
        let schemaVersion,
        let bundleIdentifier,
        let strategy,
        let relativeRoot
      else { throw E2EProfileGrantError.invalidManifest }
      return E2EProfileGrantManifest(
        schemaVersion: schemaVersion,
        bundleIdentifier: bundleIdentifier,
        strategy: strategy,
        relativeRoot: relativeRoot
      )
    }

    private mutating func decodeString() throws -> String {
      guard index < bytes.count, bytes[index] == 0x22 else {
        throw E2EProfileGrantError.invalidManifest
      }
      let start = index
      index += 1
      while index < bytes.count {
        let byte = bytes[index]
        switch byte {
        case 0x00...0x1F:
          throw E2EProfileGrantError.invalidManifest
        case 0x22:
          index += 1
          let token = Data(bytes[start..<index])
          do {
            guard
              let decoded = try JSONSerialization.jsonObject(
                with: token,
                options: [.fragmentsAllowed]
              ) as? String
            else { throw E2EProfileGrantError.invalidManifest }
            return decoded
          } catch let error as E2EProfileGrantError {
            throw error
          } catch {
            throw E2EProfileGrantError.invalidManifest
          }
        case 0x5C:
          index += 1
          guard index < bytes.count else {
            throw E2EProfileGrantError.invalidManifest
          }
          let escape = bytes[index]
          if escape == 0x75 {
            guard index + 4 < bytes.count else {
              throw E2EProfileGrantError.invalidManifest
            }
            for hexadecimal in bytes[(index + 1)...(index + 4)] {
              guard
                (0x30...0x39).contains(hexadecimal)
                  || (0x41...0x46).contains(hexadecimal)
                  || (0x61...0x66).contains(hexadecimal)
              else { throw E2EProfileGrantError.invalidManifest }
            }
            index += 5
            continue
          }
          guard [0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escape)
          else { throw E2EProfileGrantError.invalidManifest }
          index += 1
          continue
        default:
          index += 1
        }
      }
      throw E2EProfileGrantError.invalidManifest
    }

    private mutating func decodeInteger() throws -> Int {
      let start = index
      if consumeIfPresent(0x2D), index == bytes.count {
        throw E2EProfileGrantError.invalidManifest
      }
      guard index < bytes.count else {
        throw E2EProfileGrantError.invalidManifest
      }
      if bytes[index] == 0x30 {
        index += 1
        if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
          throw E2EProfileGrantError.invalidManifest
        }
      } else {
        guard (0x31...0x39).contains(bytes[index]) else {
          throw E2EProfileGrantError.invalidManifest
        }
        repeat {
          index += 1
        } while index < bytes.count
          && (0x30...0x39).contains(bytes[index])
      }
      guard
        let value = Int(String(decoding: bytes[start..<index], as: UTF8.self))
      else { throw E2EProfileGrantError.invalidManifest }
      return value
    }

    private mutating func skipWhitespace() {
      while index < bytes.count, [0x09, 0x0A, 0x0D, 0x20].contains(bytes[index]) {
        index += 1
      }
    }

    private mutating func consume(_ expected: UInt8) throws {
      guard consumeIfPresent(expected) else {
        throw E2EProfileGrantError.invalidManifest
      }
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
      guard index < bytes.count, bytes[index] == expected else { return false }
      index += 1
      return true
    }
  }

  private struct E2EFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let mode: mode_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ metadata: stat) {
      device = metadata.st_dev
      inode = metadata.st_ino
      owner = metadata.st_uid
      mode = metadata.st_mode
      size = metadata.st_size
      modifiedSeconds = metadata.st_mtimespec.tv_sec
      modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
      changedSeconds = metadata.st_ctimespec.tv_sec
      changedNanoseconds = metadata.st_ctimespec.tv_nsec
    }

    func hasSameNodeOwnerAndMode(as other: E2EFileIdentity) -> Bool {
      device == other.device
        && inode == other.inode
        && owner == other.owner
        && mode == other.mode
    }
  }
#endif
