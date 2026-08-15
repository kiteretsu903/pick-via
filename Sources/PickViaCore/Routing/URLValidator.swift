import Foundation

public enum URLValidationError: Error, Equatable, Sendable {
  case unsupportedURL
}

public struct ValidatedRoute: Equatable, Sendable {
  public let kind: RouteKind
  public let url: URL

  public init(kind: RouteKind, url: URL) {
    self.kind = kind
    self.url = url
  }
}

public enum URLValidator {
  public static func validate(_ url: URL) throws -> ValidatedRoute {
    guard let scheme = url.scheme?.lowercased() else {
      throw URLValidationError.unsupportedURL
    }

    switch scheme {
    case "http", "https":
      guard let host = url.host, !host.isEmpty else {
        throw URLValidationError.unsupportedURL
      }
      return ValidatedRoute(kind: .web, url: url)
    case "mailto":
      return ValidatedRoute(kind: .mail, url: url)
    default:
      throw URLValidationError.unsupportedURL
    }
  }
}
