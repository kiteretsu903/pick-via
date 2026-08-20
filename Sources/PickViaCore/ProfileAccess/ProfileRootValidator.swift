import Foundation

public enum ProfileRootValidation: Equatable, Sendable {
  case valid(marker: String)
  case invalid(requiredMarker: String)
  case unreadable
}

public struct BrowserProfileRootValidator: Sendable {
  private let fileSystem: any FileSystem

  public init(fileSystem: any FileSystem = FoundationFileSystem()) {
    self.fileSystem = fileSystem
  }

  public func validate(
    _ root: URL,
    for descriptor: BrowserDescriptor
  ) -> ProfileRootValidation {
    guard let marker = Self.requiredMarker(for: descriptor.family) else {
      return .invalid(requiredMarker: "")
    }

    do {
      _ = try fileSystem.read(from: root.appending(path: marker))
      return .valid(marker: marker)
    } catch {
      switch ProfileMetadataReadError(error) {
      case .absent:
        return .invalid(requiredMarker: marker)
      case .accessDenied, .other:
        return .unreadable
      }
    }
  }

  public static func requiredMarker(for family: BrowserFamily) -> String? {
    switch family {
    case .chromium:
      "Local State"
    case .firefox:
      "profiles.ini"
    case .safari, .duckDuckGo:
      nil
    }
  }
}

enum ProfileMetadataReadError {
  case absent
  case accessDenied
  case other

  init(_ error: any Error) {
    let error = error as NSError
    if error.domain == NSCocoaErrorDomain {
      switch CocoaError.Code(rawValue: error.code) {
      case .fileNoSuchFile, .fileReadNoSuchFile:
        self = .absent
        return
      case .fileReadNoPermission:
        self = .accessDenied
        return
      default:
        break
      }
    }
    if error.domain == NSPOSIXErrorDomain {
      switch POSIXErrorCode(rawValue: Int32(error.code)) {
      case .ENOENT:
        self = .absent
        return
      case .EACCES, .EPERM:
        self = .accessDenied
        return
      default:
        break
      }
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
      self = ProfileMetadataReadError(underlying)
      return
    }
    self = .other
  }
}
