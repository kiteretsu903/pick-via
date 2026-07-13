public struct PickViaConfig: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let browsers: [BrowserApplication]
    public let targets: [BrowserTarget]

    public init(
        schemaVersion: Int,
        browsers: [BrowserApplication],
        targets: [BrowserTarget]
    ) {
        self.schemaVersion = schemaVersion
        self.browsers = browsers
        self.targets = targets
    }

    public static let initial = PickViaConfig(
        schemaVersion: 1,
        browsers: [],
        targets: []
    )
}
