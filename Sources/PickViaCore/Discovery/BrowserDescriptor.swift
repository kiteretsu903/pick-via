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

  public var hasCompatibleStrategies: Bool {
    let profileIsCompatible =
      switch profileStrategy {
      case .none:
        true
      case .chromium:
        if case .chromium = launchStrategy { true } else { false }
      case .firefox:
        if case .firefox = launchStrategy { true } else { false }
      case .safariShortcut:
        launchStrategy == .workspace
      }
    let privateModeIsCompatible =
      switch privateStrategy {
      case .unsupported:
        true
      case .argument:
        switch launchStrategy {
        case .chromium, .firefox:
          true
        case .workspace, .duckDuckGo:
          false
        }
      case .duckDuckGoFire:
        launchStrategy == .duckDuckGo
      case .safariShortcut:
        launchStrategy == .workspace
      }
    return profileIsCompatible && privateModeIsCompatible
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
      bundleIdentifier: "com.apple.SafariTechnologyPreview",
      family: .safari,
      displayName: "Safari Technology Preview",
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
      bundleIdentifier: "com.google.Chrome.dev",
      displayName: "Google Chrome Dev",
      profileRoot: "Library/Application Support/Google/Chrome Dev",
      executableRelativePath: "Contents/MacOS/Google Chrome Dev"
    ),
    chromium(
      bundleIdentifier: "com.google.Chrome.canary",
      displayName: "Google Chrome Canary",
      profileRoot: "Library/Application Support/Google/Chrome Canary",
      executableRelativePath: "Contents/MacOS/Google Chrome Canary"
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
      bundleIdentifier: "com.microsoft.edgemac.Beta",
      displayName: "Microsoft Edge Beta",
      profileRoot: "Library/Application Support/Microsoft Edge Beta",
      executableRelativePath: "Contents/MacOS/Microsoft Edge Beta",
      privateArgument: "--inprivate"
    ),
    chromium(
      bundleIdentifier: "com.microsoft.edgemac.Dev",
      displayName: "Microsoft Edge Dev",
      profileRoot: "Library/Application Support/Microsoft Edge Dev",
      executableRelativePath: "Contents/MacOS/Microsoft Edge Dev",
      privateArgument: "--inprivate"
    ),
    chromium(
      bundleIdentifier: "com.microsoft.edgemac.Canary",
      displayName: "Microsoft Edge Canary",
      profileRoot: "Library/Application Support/Microsoft Edge Canary",
      executableRelativePath: "Contents/MacOS/Microsoft Edge Canary",
      privateArgument: "--inprivate"
    ),
    chromium(
      bundleIdentifier: "com.brave.Browser",
      displayName: "Brave Browser",
      profileRoot: "Library/Application Support/BraveSoftware/Brave-Browser",
      executableRelativePath: "Contents/MacOS/Brave Browser"
    ),
    chromium(
      bundleIdentifier: "com.brave.Browser.beta",
      displayName: "Brave Beta",
      profileRoot: "Library/Application Support/BraveSoftware/Brave-Browser-Beta",
      executableRelativePath: "Contents/MacOS/Brave Browser Beta"
    ),
    chromium(
      bundleIdentifier: "com.brave.Browser.nightly",
      displayName: "Brave Nightly",
      profileRoot: "Library/Application Support/BraveSoftware/Brave-Browser-Nightly",
      executableRelativePath: "Contents/MacOS/Brave Browser Nightly"
    ),
    chromium(
      bundleIdentifier: "com.vivaldi.Vivaldi",
      displayName: "Vivaldi",
      profileRoot: "Library/Application Support/Vivaldi",
      executableRelativePath: "Contents/MacOS/Vivaldi"
    ),
    chromium(
      bundleIdentifier: "com.vivaldi.Vivaldi.snapshot",
      displayName: "Vivaldi Snapshot",
      profileRoot: "Library/Application Support/Vivaldi Snapshot",
      executableRelativePath: "Contents/MacOS/Vivaldi Snapshot"
    ),
    BrowserDescriptor(
      bundleIdentifier: "org.mozilla.firefox",
      family: .firefox,
      displayName: "Firefox",
      profileStrategy: .firefox(root: "Library/Application Support/Firefox"),
      launchStrategy: .firefox(executableRelativePath: "Contents/MacOS/firefox"),
      privateStrategy: .argument("-private-window")
    ),
    BrowserDescriptor(
      bundleIdentifier: "org.mozilla.firefoxdeveloperedition",
      family: .firefox,
      displayName: "Firefox Developer Edition",
      profileStrategy: .firefox(root: "Library/Application Support/Firefox"),
      launchStrategy: .firefox(executableRelativePath: "Contents/MacOS/firefox"),
      privateStrategy: .argument("-private-window")
    ),
    BrowserDescriptor(
      bundleIdentifier: "org.mozilla.nightly",
      family: .firefox,
      displayName: "Firefox Nightly",
      profileStrategy: .firefox(root: "Library/Application Support/Firefox"),
      launchStrategy: .firefox(executableRelativePath: "Contents/MacOS/firefox"),
      privateStrategy: .argument("-private-window")
    ),
    BrowserDescriptor(
      bundleIdentifier: "com.operasoftware.Opera",
      family: .opera,
      displayName: "Opera",
      profileStrategy: .none,
      launchStrategy: .workspace,
      privateStrategy: .unsupported
    ),
    BrowserDescriptor(
      bundleIdentifier: "company.thebrowser.Browser",
      family: .arc,
      displayName: "Arc",
      profileStrategy: .none,
      launchStrategy: .workspace,
      privateStrategy: .unsupported
    ),
    BrowserDescriptor(
      bundleIdentifier: "com.kagi.kagimacOS",
      family: .orion,
      displayName: "Orion",
      profileStrategy: .none,
      launchStrategy: .workspace,
      privateStrategy: .unsupported
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
