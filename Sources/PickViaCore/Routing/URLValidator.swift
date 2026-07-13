import Foundation

public enum URLValidationError: Error, Equatable, Sendable {
    case unsupportedURL
}

public enum URLValidator {
    public static func validate(_ url: URL) throws -> URL {
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host,
            !host.isEmpty
        else {
            throw URLValidationError.unsupportedURL
        }

        return url
    }
}
