import Foundation

public struct DiscoveredProfile: Equatable, Sendable {
    public let identifier: String
    public let displayName: String
    public let directoryURL: URL?

    public init(identifier: String, displayName: String, directoryURL: URL?) {
        self.identifier = identifier
        self.displayName = displayName
        self.directoryURL = directoryURL
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
            guard currentSectionName?.hasPrefix("Profile") == true else { return }
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

        return sections.compactMap { values in
            guard
                let name = values["Name"],
                !name.isEmpty,
                let path = values["Path"],
                !path.isEmpty
            else {
                return nil
            }

            let directoryURL: URL
            if values["IsRelative"] == "1" {
                directoryURL = baseDirectory.appending(path: path, directoryHint: .isDirectory)
            } else if (path as NSString).isAbsolutePath {
                directoryURL = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                return nil
            }

            return DiscoveredProfile(
                identifier: name,
                displayName: name,
                directoryURL: directoryURL
            )
        }
        .sorted { $0.identifier < $1.identifier }
    }
}
