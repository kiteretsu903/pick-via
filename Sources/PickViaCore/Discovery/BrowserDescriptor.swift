public enum BrowserProfileStrategy: Equatable, Sendable {
  case none
  case chromium(root: String)
  case firefox(root: String)
  case safariShortcut

  var requiredProfileMarker: String? {
    switch self {
    case .none, .safariShortcut:
      nil
    case .chromium:
      "Local State"
    case .firefox:
      "profiles.ini"
    }
  }
}

public enum BrowserLaunchStrategy: Equatable, Sendable {
  case workspace
  case chromium(executableRelativePath: String, profileArgument: String)
  case firefox(executableRelativePath: String)
  case duckDuckGo
}

public enum BrowserPrivateStrategy: Equatable, Sendable {
  case unsupported
  case argument(String)
  case duckDuckGoFire
  case safariShortcut
}

public struct BrowserDescriptor: Equatable, Sendable {
  public let bundleIdentifier: String
  public let family: BrowserFamily
  public let displayName: String
  public let profileStrategy: BrowserProfileStrategy
  public let launchStrategy: BrowserLaunchStrategy
  public let privateStrategy: BrowserPrivateStrategy

  public init(
    bundleIdentifier: String,
    family: BrowserFamily,
    displayName: String,
    profileStrategy: BrowserProfileStrategy,
    launchStrategy: BrowserLaunchStrategy,
    privateStrategy: BrowserPrivateStrategy
  ) {
    self.bundleIdentifier = bundleIdentifier
    self.family = family
    self.displayName = displayName
    self.profileStrategy = profileStrategy
    self.launchStrategy = launchStrategy
    self.privateStrategy = privateStrategy
  }

  public var profileRoot: String? {
    switch profileStrategy {
    case .none, .safariShortcut:
      nil
    case .chromium(let root), .firefox(let root):
      root
    }
  }

  public var requiredProfileMarker: String? {
    profileStrategy.requiredProfileMarker
  }

  public var executableRelativePath: String? {
    switch launchStrategy {
    case .workspace, .duckDuckGo:
      nil
    case .chromium(let executableRelativePath, _), .firefox(let executableRelativePath):
      executableRelativePath
    }
  }

  public var supportsProfiles: Bool {
    switch profileStrategy {
    case .none:
      false
    case .chromium, .firefox, .safariShortcut:
      true
    }
  }

  public var supportsPrivateMode: Bool {
    switch privateStrategy {
    case .unsupported:
      false
    case .argument, .duckDuckGoFire, .safariShortcut:
      true
    }
  }

  public static let supported: [BrowserDescriptor] = [
    BrowserDescriptor(
      bundleIdentifier: "com.apple.Safari",
      family: .safari,
      displayName: "Safari",
      profileStrategy: .none,
      launchStrategy: .workspace,
      privateStrategy: .unsupported
    ),
    BrowserDescriptor(
      bundleIdentifier: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
      family: .duckDuckGo,
      displayName: "DuckDuckGo",
      profileStrategy: .none,
      launchStrategy: .duckDuckGo,
      privateStrategy: .duckDuckGoFire
    ),
    chromium(
      bundleIdentifier: "com.google.Chrome",
      displayName: "Google Chrome",
      profileRoot: "Library/Application Support/Google/Chrome",
      executableRelativePath: "Contents/MacOS/Google Chrome"
    ),
    chromium(
      bundleIdentifier: "com.google.Chrome.beta",
      displayName: "Google Chrome Beta",
      profileRoot: "Library/Application Support/Google/Chrome Beta",
      executableRelativePath: "Contents/MacOS/Google Chrome Beta"
    ),
    chromium(
      bundleIdentifier: "org.chromium.Chromium",
      displayName: "Chromium",
      profileRoot: "Library/Application Support/Chromium",
      executableRelativePath: "Contents/MacOS/Chromium"
    ),
    chromium(
      bundleIdentifier: "com.microsoft.edgemac",
      displayName: "Microsoft Edge",
      profileRoot: "Library/Application Support/Microsoft Edge",
      executableRelativePath: "Contents/MacOS/Microsoft Edge",
      privateArgument: "--inprivate"
    ),
    chromium(
      bundleIdentifier: "com.brave.Browser",
      displayName: "Brave Browser",
      profileRoot: "Library/Application Support/BraveSoftware/Brave-Browser",
      executableRelativePath: "Contents/MacOS/Brave Browser"
    ),
    chromium(
      bundleIdentifier: "com.vivaldi.Vivaldi",
      displayName: "Vivaldi",
      profileRoot: "Library/Application Support/Vivaldi",
      executableRelativePath: "Contents/MacOS/Vivaldi"
    ),
    BrowserDescriptor(
      bundleIdentifier: "org.mozilla.firefox",
      family: .firefox,
      displayName: "Firefox",
      profileStrategy: .firefox(root: "Library/Application Support/Firefox"),
      launchStrategy: .firefox(executableRelativePath: "Contents/MacOS/firefox"),
      privateStrategy: .argument("-private-window")
    ),
  ]

  public static func family(forBundleIdentifier bundleIdentifier: String) -> BrowserFamily? {
    descriptor(forBundleIdentifier: bundleIdentifier)?.family
  }

  public static func descriptor(forBundleIdentifier bundleIdentifier: String) -> BrowserDescriptor?
  {
    supported.first { $0.bundleIdentifier == bundleIdentifier }
  }

  private static func chromium(
    bundleIdentifier: String,
    displayName: String,
    profileRoot: String,
    executableRelativePath: String,
    privateArgument: String = "--incognito"
  ) -> BrowserDescriptor {
    BrowserDescriptor(
      bundleIdentifier: bundleIdentifier,
      family: .chromium,
      displayName: displayName,
      profileStrategy: .chromium(root: profileRoot),
      launchStrategy: .chromium(
        executableRelativePath: executableRelativePath,
        profileArgument: "--profile-directory="
      ),
      privateStrategy: .argument(privateArgument)
    )
  }
}
