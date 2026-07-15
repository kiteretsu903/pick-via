import CryptoKit
import Foundation

public struct DiscoveredProfile: Equatable, Sendable {
  public let identifier: String
  public let displayName: String
  public let directoryURL: URL?
  public let launchIdentifier: String

  public init(
    identifier: String,
    displayName: String,
    directoryURL: URL?,
    launchIdentifier: String? = nil
  ) {
    self.identifier = identifier
    self.displayName = displayName
    self.directoryURL = directoryURL
    self.launchIdentifier = launchIdentifier ?? identifier
  }
}

public enum ChromiumProfileParser {
  public static func parse(data: Data) throws -> [DiscoveredProfile] {
    let value = try JSONSerialization.jsonObject(with: data)
    guard
      let root = value as? [String: Any],
      let profile = root["profile"] as? [String: Any],
      let infoCache = profile["info_cache"] as? [String: Any]
    else {
      return []
    }

    return infoCache.compactMap { identifier, value in
      guard
        !identifier.isEmpty,
        let metadata = value as? [String: Any],
        let displayName = metadata["name"] as? String,
        !displayName.isEmpty
      else {
        return nil
      }
      return DiscoveredProfile(
        identifier: identifier,
        displayName: displayName,
        directoryURL: nil
      )
    }
    .sorted { $0.identifier < $1.identifier }
  }
}

public enum FirefoxProfileParser {
  public static func parse(text: String, baseDirectory: URL) throws -> [DiscoveredProfile] {
    var sections: [[String: String]] = []
    var currentSectionName: String?
    var currentValues: [String: String] = [:]

    func appendCurrentSection() {
      guard
        let name = currentSectionName,
        isNumericProfileSection(name)
      else { return }
      sections.append(currentValues)
    }

    for rawLine in text.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix(";") && !line.hasPrefix("#") else {
        continue
      }
      if line.hasPrefix("[") && line.hasSuffix("]") {
        appendCurrentSection()
        currentSectionName = String(line.dropFirst().dropLast())
        currentValues = [:]
        continue
      }
      guard currentSectionName != nil, let separator = line.firstIndex(of: "=") else {
        continue
      }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      currentValues[key] = value
    }
    appendCurrentSection()

    return try sections.map { values in
      guard
        let name = values["Name"],
        !name.isEmpty,
        let path = values["Path"],
        !path.isEmpty,
        let isRelative = values["IsRelative"],
        isRelative == "0" || isRelative == "1"
      else {
        throw FirefoxProfileParserError.malformedProfileSection
      }

      let directoryURL: URL
      if isRelative == "1" {
        guard !(path as NSString).isAbsolutePath else {
          throw FirefoxProfileParserError.malformedProfileSection
        }
        directoryURL = baseDirectory.appending(path: path, directoryHint: .isDirectory)
      } else if (path as NSString).isAbsolutePath {
        directoryURL = URL(fileURLWithPath: path, isDirectory: true)
      } else {
        throw FirefoxProfileParserError.malformedProfileSection
      }

      let normalizedURL = directoryURL.standardizedFileURL
      return DiscoveredProfile(
        identifier: FirefoxProfileIdentity.identifier(for: normalizedURL),
        displayName: name,
        directoryURL: normalizedURL,
        launchIdentifier: name
      )
    }
    .sorted { $0.identifier < $1.identifier }
  }

  private static func isNumericProfileSection(_ name: String) -> Bool {
    guard name.hasPrefix("Profile") else { return false }
    let suffix = name.dropFirst("Profile".count)
    return !suffix.isEmpty
      && suffix.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
  }
}

public enum FirefoxProfileParserError: Error, Equatable, Sendable {
  case malformedProfileSection
}

public enum FirefoxProfileIdentity {
  public static let prefix = "firefox-profile-v1:"

  public static func identifier(for directoryURL: URL) -> String {
    identifier(forNormalizedPath: directoryURL.standardizedFileURL.path)
  }

  public static func isOpaqueIdentifier(_ value: String) -> Bool {
    guard value.hasPrefix(prefix) else { return false }
    let digest = value.dropFirst(prefix.count)
    let lowercaseHex = Set("0123456789abcdef")
    return digest.count == SHA256.byteCount * 2
      && digest.allSatisfy(lowercaseHex.contains)
  }

  static func identifier(forNormalizedPath path: String) -> String {
    let digest = SHA256.hash(data: Data(path.utf8))
    let hexadecimal = digest.map { String(format: "%02x", $0) }.joined()
    return prefix + hexadecimal
  }

  static func identifier(forLegacyValue value: String) -> String {
    identifier(forNormalizedPath: value)
  }
}
