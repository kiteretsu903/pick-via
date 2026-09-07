import Testing

@testable import PickViaCore

struct BrowserDescriptorTests {
  @Test(arguments: descriptorExpectations)
  func supportedDescriptorCarriesExactStrategies(_ expectation: DescriptorExpectation) throws {
    let descriptor = try #require(
      BrowserDescriptor.descriptor(forBundleIdentifier: expectation.bundleIdentifier)
    )

    #expect(descriptor.family == expectation.family)
    #expect(descriptor.displayName == expectation.displayName)
    #expect(descriptor.profileStrategy == expectation.profileStrategy)
    #expect(descriptor.launchStrategy == expectation.launchStrategy)
    #expect(descriptor.privateStrategy == expectation.privateStrategy)
    #expect(descriptor.routeCapabilityPolicy == expectation.routeCapabilityPolicy)
    #expect(descriptor.profileRoot == expectation.profileRoot)
    #expect(descriptor.requiredProfileMarker == expectation.requiredProfileMarker)
    #expect(descriptor.executableRelativePath == expectation.executableRelativePath)
    #expect(descriptor.supportsProfiles == expectation.supportsProfiles)
    #expect(descriptor.supportsPrivateMode == expectation.supportsPrivateMode)
  }

  @Test func builtInDescriptorsHaveCompatibleStrategies() {
    #expect(BrowserDescriptor.supported.allSatisfy { $0.hasCompatibleStrategies })
  }

  @Test(arguments: incompatibleStrategyCombinations)
  func incompatibleStrategyCombinationsAreRejected(_ combination: StrategyCombination) {
    #expect(!strategyDescriptor(combination).hasCompatibleStrategies)
  }

  @Test(arguments: compatibleStrategyCombinations)
  func compatibleStrategyCombinationsAreAccepted(_ combination: StrategyCombination) {
    #expect(strategyDescriptor(combination).hasCompatibleStrategies)
  }

  @Test func privateCapabilityResolverKeepsStaticArgumentsAndFailClosedDynamicEvidence() {
    let applicationID = "com.example.private-capability"
    let argumentEnabled = BrowserDescriptor(
      bundleIdentifier: applicationID,
      family: .chromium,
      displayName: "Argument Browser",
      profileStrategy: .none,
      launchStrategy: .chromium(
        executableRelativePath: "Contents/MacOS/browser",
        profileArgument: "--profile="
      ),
      privateStrategy: .argument("--private"),
      routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
        normal: .executable,
        browserPrivate: true,
        profile: false,
        profilePrivate: false
      )
    )
    let argumentDisabled = BrowserDescriptor(
      bundleIdentifier: applicationID,
      family: .chromium,
      displayName: "Argument Browser",
      profileStrategy: .none,
      launchStrategy: .chromium(
        executableRelativePath: "Contents/MacOS/browser",
        profileArgument: "--profile="
      ),
      privateStrategy: .argument("--private"),
      routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
        normal: .executable,
        browserPrivate: false,
        profile: false,
        profilePrivate: false
      )
    )
    let unsupported = BrowserDescriptor(
      bundleIdentifier: applicationID,
      family: .opera,
      displayName: "Unsupported Browser",
      profileStrategy: .none,
      launchStrategy: .workspace,
      privateStrategy: .unsupported
    )
    let duckDuckGoEnabled = BrowserDescriptor(
      bundleIdentifier: applicationID,
      family: .duckDuckGo,
      displayName: "Dynamic Browser",
      profileStrategy: .none,
      launchStrategy: .duckDuckGo,
      privateStrategy: .duckDuckGoFire,
      routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
        normal: .executable,
        browserPrivate: true,
        profile: false,
        profilePrivate: false
      )
    )
    let duckDuckGoDisabled = BrowserDescriptor(
      bundleIdentifier: applicationID,
      family: .duckDuckGo,
      displayName: "Dynamic Browser",
      profileStrategy: .none,
      launchStrategy: .duckDuckGo,
      privateStrategy: .duckDuckGoFire,
      routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
        normal: .executable,
        browserPrivate: false,
        profile: false,
        profilePrivate: false
      )
    )
    let safariShortcut = BrowserDescriptor(
      bundleIdentifier: applicationID,
      family: .safari,
      displayName: "Shortcut Browser",
      profileStrategy: .safariShortcut,
      launchStrategy: .workspace,
      privateStrategy: .safariShortcut
    )
    let unavailablePrivate = privateCapabilityTarget(
      applicationID: applicationID,
      availability: .unavailable
    )
    let availablePrivate = privateCapabilityTarget(
      applicationID: applicationID,
      availability: .available
    )
    let collidingMailTarget = RouteTarget(
      id: availablePrivate.id,
      applicationID: applicationID,
      label: "Private",
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available,
      capability: .mail
    )

    #expect(
      BrowserPrivateCapabilityResolver.isAvailable(
        descriptor: argumentEnabled,
        applicationID: applicationID,
        targets: []
      ))
    #expect(
      !BrowserPrivateCapabilityResolver.isAvailable(
        descriptor: argumentDisabled,
        applicationID: applicationID,
        targets: [availablePrivate]
      ))
    #expect(
      !BrowserPrivateCapabilityResolver.isAvailable(
        descriptor: unsupported,
        applicationID: applicationID,
        targets: [availablePrivate]
      ))
    #expect(
      !BrowserPrivateCapabilityResolver.isAvailable(
        descriptor: duckDuckGoDisabled,
        applicationID: applicationID,
        targets: [availablePrivate]
      ))
    for descriptor in [duckDuckGoEnabled] {
      #expect(
        !BrowserPrivateCapabilityResolver.isAvailable(
          descriptor: descriptor,
          applicationID: applicationID,
          targets: []
        ))
      #expect(
        !BrowserPrivateCapabilityResolver.isAvailable(
          descriptor: descriptor,
          applicationID: applicationID,
          targets: [unavailablePrivate]
        ))
      #expect(
        !BrowserPrivateCapabilityResolver.isAvailable(
          descriptor: descriptor,
          applicationID: applicationID,
          targets: [collidingMailTarget]
        ))
      #expect(
        BrowserPrivateCapabilityResolver.isAvailable(
          descriptor: descriptor,
          applicationID: applicationID,
          targets: [availablePrivate]
        ))
    }
    #expect(
      !BrowserPrivateCapabilityResolver.isAvailable(
        descriptor: safariShortcut,
        applicationID: applicationID,
        targets: [availablePrivate]
      ))
  }

  @Test func routeCapabilityPolicyAnswersEveryExactProfileAndModeCombination() {
    let ordinary = BrowserRouteCapabilityPolicy(
      normal: .workspace,
      browserPrivate: true,
      profile: true,
      profilePrivate: false
    )
    #expect(ordinary.supportsRoute(hasProfile: false, mode: .normal))
    #expect(ordinary.supportsRoute(hasProfile: false, mode: .private))
    #expect(ordinary.supportsRoute(hasProfile: true, mode: .normal))
    #expect(!ordinary.supportsRoute(hasProfile: true, mode: .private))

    let profilePrivateOnly = BrowserRouteCapabilityPolicy(
      normal: .unsupported,
      browserPrivate: false,
      profile: false,
      profilePrivate: true
    )
    #expect(!profilePrivateOnly.supportsRoute(hasProfile: false, mode: .normal))
    #expect(!profilePrivateOnly.supportsRoute(hasProfile: false, mode: .private))
    #expect(!profilePrivateOnly.supportsRoute(hasProfile: true, mode: .normal))
    #expect(profilePrivateOnly.supportsRoute(hasProfile: true, mode: .private))
  }

  @Test func workspaceSafariShortcutDefaultDoesNotClaimDormantEnhancedRoutes() {
    let descriptor = BrowserDescriptor(
      bundleIdentifier: "com.example.default-safari-shortcut",
      family: .safari,
      displayName: "Default Safari Shortcut",
      profileStrategy: .safariShortcut,
      launchStrategy: .workspace,
      privateStrategy: .safariShortcut
    )

    #expect(
      descriptor.routeCapabilityPolicy
        == BrowserRouteCapabilityPolicy(
          normal: .workspace,
          browserPrivate: false,
          profile: false,
          profilePrivate: false
        ))
    #expect(descriptor.hasCompatibleStrategies)
    #expect(descriptor.supportsRoute(hasProfile: false, mode: .normal))
    #expect(!descriptor.supportsRoute(hasProfile: false, mode: .private))
    #expect(!descriptor.supportsRoute(hasProfile: true, mode: .normal))
    #expect(!descriptor.supportsRoute(hasProfile: true, mode: .private))

    let contradictory = BrowserDescriptor(
      bundleIdentifier: descriptor.bundleIdentifier,
      family: descriptor.family,
      displayName: descriptor.displayName,
      profileStrategy: descriptor.profileStrategy,
      launchStrategy: descriptor.launchStrategy,
      privateStrategy: descriptor.privateStrategy,
      routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
        normal: .workspace,
        browserPrivate: true,
        profile: true,
        profilePrivate: true
      )
    )
    #expect(!contradictory.hasCompatibleStrategies)
    #expect(!contradictory.supportsRoute(hasProfile: false, mode: .normal))
  }
}

private func privateCapabilityTarget(
  applicationID: String,
  availability: TargetAvailability
) -> RouteTarget {
  RouteTarget(
    id: BrowserCatalog.targetID(
      bundleIdentifier: applicationID,
      profileIdentifier: nil,
      mode: .private
    ),
    applicationID: applicationID,
    label: "Private",
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: availability,
    capability: .browser(
      BrowserTargetOptions(
        profileIdentifier: nil,
        profileDisplayName: nil,
        profileIdentity: nil,
        profileLaunchPath: nil,
        mode: .private,
        pendingDefaultMigration: false,
        validationError: nil
      )
    )
  )
}

struct DescriptorExpectation: Sendable {
  let bundleIdentifier: String
  let family: BrowserFamily
  let displayName: String
  let profileStrategy: BrowserProfileStrategy
  let launchStrategy: BrowserLaunchStrategy
  let privateStrategy: BrowserPrivateStrategy
  let routeCapabilityPolicy: BrowserRouteCapabilityPolicy
  let profileRoot: String?
  let requiredProfileMarker: String?
  let executableRelativePath: String?
  let supportsProfiles: Bool
  let supportsPrivateMode: Bool
}

let descriptorExpectations = [
  DescriptorExpectation(
    bundleIdentifier: "com.apple.Safari",
    family: .safari,
    displayName: "Safari",
    profileStrategy: .safariAccessibility,
    launchStrategy: .workspace,
    privateStrategy: .unsupported,
    routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
      normal: .workspace,
      browserPrivate: false,
      profile: true,
      profilePrivate: false
    ),
    profileRoot: nil,
    requiredProfileMarker: nil,
    executableRelativePath: nil,
    supportsProfiles: true,
    supportsPrivateMode: false
  ),
  DescriptorExpectation(
    bundleIdentifier: "com.apple.SafariTechnologyPreview",
    family: .safari,
    displayName: "Safari Technology Preview",
    profileStrategy: .none,
    launchStrategy: .workspace,
    privateStrategy: .unsupported,
    routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
      normal: .workspace,
      browserPrivate: false,
      profile: false,
      profilePrivate: false
    ),
    profileRoot: nil,
    requiredProfileMarker: nil,
    executableRelativePath: nil,
    supportsProfiles: false,
    supportsPrivateMode: false
  ),
  DescriptorExpectation(
    bundleIdentifier: "com.duckduckgo.macos.browser",
    family: .duckDuckGo,
    displayName: "DuckDuckGo",
    profileStrategy: .none,
    launchStrategy: .duckDuckGo,
    privateStrategy: .duckDuckGoFire,
    routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
      normal: .executable,
      browserPrivate: true,
      profile: false,
      profilePrivate: false
    ),
    profileRoot: nil,
    requiredProfileMarker: nil,
    executableRelativePath: nil,
    supportsProfiles: false,
    supportsPrivateMode: true
  ),
  chromiumExpectation(
    bundleIdentifier: "com.google.Chrome",
    displayName: "Google Chrome",
    profileRoot: "Library/Application Support/Google/Chrome",
    executableRelativePath: "Contents/MacOS/Google Chrome"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.google.Chrome.beta",
    displayName: "Google Chrome Beta",
    profileRoot: "Library/Application Support/Google/Chrome Beta",
    executableRelativePath: "Contents/MacOS/Google Chrome Beta"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.google.Chrome.dev",
    displayName: "Google Chrome Dev",
    profileRoot: "Library/Application Support/Google/Chrome Dev",
    executableRelativePath: "Contents/MacOS/Google Chrome Dev"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.google.Chrome.canary",
    displayName: "Google Chrome Canary",
    profileRoot: "Library/Application Support/Google/Chrome Canary",
    executableRelativePath: "Contents/MacOS/Google Chrome Canary"
  ),
  chromiumExpectation(
    bundleIdentifier: "org.chromium.Chromium",
    displayName: "Chromium",
    profileRoot: "Library/Application Support/Chromium",
    executableRelativePath: "Contents/MacOS/Chromium"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.microsoft.edgemac",
    displayName: "Microsoft Edge",
    profileRoot: "Library/Application Support/Microsoft Edge",
    executableRelativePath: "Contents/MacOS/Microsoft Edge",
    privateArgument: "--inprivate"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.microsoft.edgemac.Beta",
    displayName: "Microsoft Edge Beta",
    profileRoot: "Library/Application Support/Microsoft Edge Beta",
    executableRelativePath: "Contents/MacOS/Microsoft Edge Beta",
    privateArgument: "--inprivate"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.microsoft.edgemac.Dev",
    displayName: "Microsoft Edge Dev",
    profileRoot: "Library/Application Support/Microsoft Edge Dev",
    executableRelativePath: "Contents/MacOS/Microsoft Edge Dev",
    privateArgument: "--inprivate"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.microsoft.edgemac.Canary",
    displayName: "Microsoft Edge Canary",
    profileRoot: "Library/Application Support/Microsoft Edge Canary",
    executableRelativePath: "Contents/MacOS/Microsoft Edge Canary",
    privateArgument: "--inprivate"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.brave.Browser",
    displayName: "Brave Browser",
    profileRoot: "Library/Application Support/BraveSoftware/Brave-Browser",
    executableRelativePath: "Contents/MacOS/Brave Browser"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.brave.Browser.beta",
    displayName: "Brave Beta",
    profileRoot: "Library/Application Support/BraveSoftware/Brave-Browser-Beta",
    executableRelativePath: "Contents/MacOS/Brave Browser Beta"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.brave.Browser.nightly",
    displayName: "Brave Nightly",
    profileRoot: "Library/Application Support/BraveSoftware/Brave-Browser-Nightly",
    executableRelativePath: "Contents/MacOS/Brave Browser Nightly"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.vivaldi.Vivaldi",
    displayName: "Vivaldi",
    profileRoot: "Library/Application Support/Vivaldi",
    executableRelativePath: "Contents/MacOS/Vivaldi"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.vivaldi.Vivaldi.snapshot",
    displayName: "Vivaldi Snapshot",
    profileRoot: "Library/Application Support/Vivaldi Snapshot",
    executableRelativePath: "Contents/MacOS/Vivaldi Snapshot"
  ),
  firefoxExpectation(
    bundleIdentifier: "org.mozilla.firefox",
    displayName: "Firefox"
  ),
  firefoxExpectation(
    bundleIdentifier: "org.mozilla.firefoxdeveloperedition",
    displayName: "Firefox Developer Edition"
  ),
  firefoxExpectation(
    bundleIdentifier: "org.mozilla.nightly",
    displayName: "Firefox Nightly"
  ),
  failClosedExpectation(
    bundleIdentifier: "com.operasoftware.Opera",
    family: .opera,
    displayName: "Opera"
  ),
  failClosedExpectation(
    bundleIdentifier: "company.thebrowser.Browser",
    family: .arc,
    displayName: "Arc"
  ),
  failClosedExpectation(
    bundleIdentifier: "com.kagi.kagimacOS",
    family: .orion,
    displayName: "Orion"
  ),
]

func failClosedExpectation(
  bundleIdentifier: String,
  family: BrowserFamily,
  displayName: String
) -> DescriptorExpectation {
  DescriptorExpectation(
    bundleIdentifier: bundleIdentifier,
    family: family,
    displayName: displayName,
    profileStrategy: .none,
    launchStrategy: .workspace,
    privateStrategy: .unsupported,
    routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
      normal: .workspace,
      browserPrivate: false,
      profile: false,
      profilePrivate: false
    ),
    profileRoot: nil,
    requiredProfileMarker: nil,
    executableRelativePath: nil,
    supportsProfiles: false,
    supportsPrivateMode: false
  )
}

func chromiumExpectation(
  bundleIdentifier: String,
  displayName: String,
  profileRoot: String,
  executableRelativePath: String,
  privateArgument: String = "--incognito"
) -> DescriptorExpectation {
  DescriptorExpectation(
    bundleIdentifier: bundleIdentifier,
    family: .chromium,
    displayName: displayName,
    profileStrategy: .chromium(root: profileRoot),
    launchStrategy: .chromium(
      executableRelativePath: executableRelativePath,
      profileArgument: "--profile-directory="
    ),
    privateStrategy: .argument(privateArgument),
    routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
      normal: .workspace,
      browserPrivate: true,
      profile: true,
      profilePrivate: false
    ),
    profileRoot: profileRoot,
    requiredProfileMarker: "Local State",
    executableRelativePath: executableRelativePath,
    supportsProfiles: true,
    supportsPrivateMode: true
  )
}

func firefoxExpectation(
  bundleIdentifier: String,
  displayName: String
) -> DescriptorExpectation {
  DescriptorExpectation(
    bundleIdentifier: bundleIdentifier,
    family: .firefox,
    displayName: displayName,
    profileStrategy: .firefox(root: "Library/Application Support/Firefox"),
    launchStrategy: .firefox(executableRelativePath: "Contents/MacOS/firefox"),
    privateStrategy: .argument("-private-window"),
    routeCapabilityPolicy: BrowserRouteCapabilityPolicy(
      normal: .executable,
      browserPrivate: true,
      profile: true,
      profilePrivate: false
    ),
    profileRoot: "Library/Application Support/Firefox",
    requiredProfileMarker: "profiles.ini",
    executableRelativePath: "Contents/MacOS/firefox",
    supportsProfiles: true,
    supportsPrivateMode: true
  )
}

struct StrategyCombination: Sendable {
  let profile: BrowserProfileStrategy
  let launch: BrowserLaunchStrategy
  let privateMode: BrowserPrivateStrategy
}

let incompatibleStrategyCombinations = [
  StrategyCombination(
    profile: .chromium(root: "root"), launch: .workspace, privateMode: .unsupported),
  StrategyCombination(
    profile: .chromium(root: "root"),
    launch: .firefox(executableRelativePath: "firefox"),
    privateMode: .unsupported
  ),
  StrategyCombination(
    profile: .chromium(root: "root"), launch: .duckDuckGo, privateMode: .unsupported),
  StrategyCombination(
    profile: .firefox(root: "root"), launch: .workspace, privateMode: .unsupported),
  StrategyCombination(
    profile: .firefox(root: "root"),
    launch: .chromium(executableRelativePath: "chromium", profileArgument: "--profile="),
    privateMode: .unsupported
  ),
  StrategyCombination(
    profile: .firefox(root: "root"), launch: .duckDuckGo, privateMode: .unsupported),
  StrategyCombination(
    profile: .safariShortcut,
    launch: .chromium(executableRelativePath: "chromium", profileArgument: "--profile="),
    privateMode: .unsupported
  ),
  StrategyCombination(
    profile: .safariShortcut,
    launch: .firefox(executableRelativePath: "firefox"),
    privateMode: .unsupported
  ),
  StrategyCombination(profile: .safariShortcut, launch: .duckDuckGo, privateMode: .unsupported),
  StrategyCombination(profile: .none, launch: .workspace, privateMode: .duckDuckGoFire),
  StrategyCombination(
    profile: .none,
    launch: .chromium(executableRelativePath: "chromium", profileArgument: "--profile="),
    privateMode: .duckDuckGoFire
  ),
  StrategyCombination(
    profile: .none,
    launch: .firefox(executableRelativePath: "firefox"),
    privateMode: .duckDuckGoFire
  ),
  StrategyCombination(profile: .none, launch: .workspace, privateMode: .argument("--private")),
  StrategyCombination(profile: .none, launch: .duckDuckGo, privateMode: .argument("--private")),
  StrategyCombination(
    profile: .none,
    launch: .chromium(executableRelativePath: "chromium", profileArgument: "--profile="),
    privateMode: .safariShortcut
  ),
  StrategyCombination(
    profile: .none,
    launch: .firefox(executableRelativePath: "firefox"),
    privateMode: .safariShortcut
  ),
  StrategyCombination(profile: .none, launch: .duckDuckGo, privateMode: .safariShortcut),
]

let compatibleStrategyCombinations = [
  StrategyCombination(profile: .none, launch: .workspace, privateMode: .unsupported),
  StrategyCombination(
    profile: .none,
    launch: .chromium(executableRelativePath: "chromium", profileArgument: "--profile="),
    privateMode: .unsupported
  ),
  StrategyCombination(
    profile: .none,
    launch: .firefox(executableRelativePath: "firefox"),
    privateMode: .unsupported
  ),
  StrategyCombination(profile: .none, launch: .duckDuckGo, privateMode: .unsupported),
  StrategyCombination(
    profile: .chromium(root: "root"),
    launch: .chromium(executableRelativePath: "chromium", profileArgument: "--profile="),
    privateMode: .argument("--private")
  ),
  StrategyCombination(
    profile: .firefox(root: "root"),
    launch: .firefox(executableRelativePath: "firefox"),
    privateMode: .argument("--private")
  ),
  StrategyCombination(
    profile: .safariShortcut, launch: .workspace, privateMode: .safariShortcut),
  StrategyCombination(profile: .none, launch: .duckDuckGo, privateMode: .duckDuckGoFire),
]

func strategyDescriptor(_ combination: StrategyCombination) -> BrowserDescriptor {
  BrowserDescriptor(
    bundleIdentifier: "com.example.strategy-test",
    family: .chromium,
    displayName: "Strategy Test",
    profileStrategy: combination.profile,
    launchStrategy: combination.launch,
    privateStrategy: combination.privateMode
  )
}
