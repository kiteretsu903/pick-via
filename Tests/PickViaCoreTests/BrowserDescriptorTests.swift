import Testing

@testable import PickViaCore

struct BrowserDescriptorTests {
  @Test(arguments: descriptorExpectations)
  func supportedDescriptorCarriesExactStrategies(_ expectation: DescriptorExpectation) throws {
    let descriptor = try #require(
      BrowserDescriptor.descriptor(forBundleIdentifier: expectation.bundleIdentifier)
    )

    #expect(descriptor.profileStrategy == expectation.profileStrategy)
    #expect(descriptor.launchStrategy == expectation.launchStrategy)
    #expect(descriptor.privateStrategy == expectation.privateStrategy)
    #expect(descriptor.profileRoot == expectation.profileRoot)
    #expect(descriptor.requiredProfileMarker == expectation.requiredProfileMarker)
    #expect(descriptor.executableRelativePath == expectation.executableRelativePath)
    #expect(descriptor.supportsProfiles == expectation.supportsProfiles)
    #expect(descriptor.supportsPrivateMode == expectation.supportsPrivateMode)
  }
}

struct DescriptorExpectation: Sendable {
  let bundleIdentifier: String
  let profileStrategy: BrowserProfileStrategy
  let launchStrategy: BrowserLaunchStrategy
  let privateStrategy: BrowserPrivateStrategy
  let profileRoot: String?
  let requiredProfileMarker: String?
  let executableRelativePath: String?
  let supportsProfiles: Bool
  let supportsPrivateMode: Bool
}

let descriptorExpectations = [
  DescriptorExpectation(
    bundleIdentifier: "com.apple.Safari",
    profileStrategy: .none,
    launchStrategy: .workspace,
    privateStrategy: .unsupported,
    profileRoot: nil,
    requiredProfileMarker: nil,
    executableRelativePath: nil,
    supportsProfiles: false,
    supportsPrivateMode: false
  ),
  DescriptorExpectation(
    bundleIdentifier: "com.duckduckgo.macos.browser",
    profileStrategy: .none,
    launchStrategy: .duckDuckGo,
    privateStrategy: .duckDuckGoFire,
    profileRoot: nil,
    requiredProfileMarker: nil,
    executableRelativePath: nil,
    supportsProfiles: false,
    supportsPrivateMode: true
  ),
  chromiumExpectation(
    bundleIdentifier: "com.google.Chrome",
    profileRoot: "Library/Application Support/Google/Chrome",
    executableRelativePath: "Contents/MacOS/Google Chrome"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.google.Chrome.beta",
    profileRoot: "Library/Application Support/Google/Chrome Beta",
    executableRelativePath: "Contents/MacOS/Google Chrome Beta"
  ),
  chromiumExpectation(
    bundleIdentifier: "org.chromium.Chromium",
    profileRoot: "Library/Application Support/Chromium",
    executableRelativePath: "Contents/MacOS/Chromium"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.microsoft.edgemac",
    profileRoot: "Library/Application Support/Microsoft Edge",
    executableRelativePath: "Contents/MacOS/Microsoft Edge",
    privateArgument: "--inprivate"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.brave.Browser",
    profileRoot: "Library/Application Support/BraveSoftware/Brave-Browser",
    executableRelativePath: "Contents/MacOS/Brave Browser"
  ),
  chromiumExpectation(
    bundleIdentifier: "com.vivaldi.Vivaldi",
    profileRoot: "Library/Application Support/Vivaldi",
    executableRelativePath: "Contents/MacOS/Vivaldi"
  ),
  DescriptorExpectation(
    bundleIdentifier: "org.mozilla.firefox",
    profileStrategy: .firefox(root: "Library/Application Support/Firefox"),
    launchStrategy: .firefox(executableRelativePath: "Contents/MacOS/firefox"),
    privateStrategy: .argument("-private-window"),
    profileRoot: "Library/Application Support/Firefox",
    requiredProfileMarker: "profiles.ini",
    executableRelativePath: "Contents/MacOS/firefox",
    supportsProfiles: true,
    supportsPrivateMode: true
  ),
]

func chromiumExpectation(
  bundleIdentifier: String,
  profileRoot: String,
  executableRelativePath: String,
  privateArgument: String = "--incognito"
) -> DescriptorExpectation {
  DescriptorExpectation(
    bundleIdentifier: bundleIdentifier,
    profileStrategy: .chromium(root: profileRoot),
    launchStrategy: .chromium(
      executableRelativePath: executableRelativePath,
      profileArgument: "--profile-directory="
    ),
    privateStrategy: .argument(privateArgument),
    profileRoot: profileRoot,
    requiredProfileMarker: "Local State",
    executableRelativePath: executableRelativePath,
    supportsProfiles: true,
    supportsPrivateMode: true
  )
}
