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
    ) throws {
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
      else { return }
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

      try validateSyntheticProfile(
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
      let value: Any
      do {
        value = try JSONSerialization.jsonObject(with: data)
      } catch {
        throw E2EProfileGrantError.invalidManifest
      }
      guard let object = value as? [String: Any] else {
        throw E2EProfileGrantError.invalidManifest
      }
      let expectedKeys = Set([
        "schemaVersion", "bundleIdentifier", "strategy", "relativeRoot",
      ])
      guard Set(object.keys) == expectedKeys,
        let schema = object["schemaVersion"] as? NSNumber,
        CFGetTypeID(schema) != CFBooleanGetTypeID(),
        schema.doubleValue.isFinite,
        schema.doubleValue == Double(schema.intValue),
        object["bundleIdentifier"] is String,
        object["strategy"] is String,
        object["relativeRoot"] is String
      else { throw E2EProfileGrantError.invalidManifest }
      do {
        return try JSONDecoder().decode(E2EProfileGrantManifest.self, from: data)
      } catch {
        throw E2EProfileGrantError.invalidManifest
      }
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
    ) throws {
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
        _ = try validatedDirectoryIdentity(
          descriptor: childDescriptor,
          publicURL: childURL,
          ownerUID: ownerUID,
          requiredDevice: rootIdentity.device,
          requiresRestrictedMode: true
        )
      } catch {
        throw E2EProfileGrantError.invalidProfiles
      }
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

    private static func openDirectory(_ url: URL) throws -> Int32 {
      let descriptor = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard descriptor >= 0 else { throw E2EProfileGrantError.invalidRoot }
      return descriptor
    }

    private static func openDirectory(
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

    private static func validatedDirectoryIdentity(
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
  }
#endif
