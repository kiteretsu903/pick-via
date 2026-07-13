import Foundation

public protocol ConfigStoring: Sendable {
    func load() throws -> PickViaConfig
    func save(_ config: PickViaConfig) throws
}

public struct JSONConfigStore: ConfigStoring, Sendable {
    public let directory: URL
    private let now: @Sendable () -> Date

    public init(
        directory: URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.now = now
    }

    private var fileURL: URL {
        directory.appending(path: "PickViaConfig.json")
    }

    public func load() throws -> PickViaConfig {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .initial
        }

        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(PickViaConfig.self, from: data)
        } catch {
            let quarantine = directory.appending(
                path: "PickViaConfig.json.corrupt-\(Int(now().timeIntervalSince1970))"
            )
            try FileManager.default.moveItem(at: fileURL, to: quarantine)
            return .initial
        }
    }

    public func save(_ config: PickViaConfig) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporary = directory.appending(path: "PickViaConfig.json.tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: temporary, options: .atomic)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }
}
