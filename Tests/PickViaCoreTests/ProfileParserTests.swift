import Foundation
import Testing

@testable import PickViaCore

struct ProfileParserTests {
  @Test func chromiumParsesInfoCacheAndSkipsMalformedEntriesInStableOrder() throws {
    let profiles = try ChromiumProfileParser.parse(data: fixtureData("chromium-local-state.json"))

    #expect(
      profiles == [
        DiscoveredProfile(
          identifier: "Default",
          displayName: "Personal",
          directoryURL: nil,
          isDefault: true
        ),
        DiscoveredProfile(
          identifier: "Profile 1",
          displayName: "Work",
          directoryURL: nil
        ),
      ])
  }

  @Test func chromiumRejectsInvalidJSON() {
    #expect(throws: (any Error).self) {
      try ChromiumProfileParser.parse(data: Data("not json".utf8))
    }
  }

  @Test func chromiumMarksOnlyTheCanonicalDefaultDirectoryAsDefault() throws {
    let profiles = try ChromiumProfileParser.parse(data: fixtureData("chromium-local-state.json"))

    #expect(profiles.first { $0.identifier == "Default" }?.isDefault == true)
    #expect(profiles.first { $0.identifier == "Profile 1" }?.isDefault == false)
  }

  @Test func firefoxResolvesRelativeAndAbsolutePaths() throws {
    let baseDirectory = URL(fileURLWithPath: "/Users/example/Firefox", isDirectory: true)
    let profiles = try FirefoxProfileParser.parse(
      text: fixtureText("firefox-profiles.ini"),
      baseDirectory: baseDirectory
    )

    #expect(
      profiles == [
        DiscoveredProfile(
          identifier: FirefoxProfileIdentity.identifier(
            for: baseDirectory.appending(
              path: "Profiles/personal.default-release", directoryHint: .isDirectory)
          ),
          displayName: "Personal",
          directoryURL: baseDirectory.appending(
            path: "Profiles/personal.default-release", directoryHint: .isDirectory),
          launchIdentifier: "Personal"
        ),
        DiscoveredProfile(
          identifier: FirefoxProfileIdentity.identifier(
            for: URL(
              fileURLWithPath: "/Users/example/Firefox/Profiles/work", isDirectory: true)
          ),
          displayName: "Work",
          directoryURL: URL(
            fileURLWithPath: "/Users/example/Firefox/Profiles/work", isDirectory: true),
          launchIdentifier: "Work"
        ),
      ])
  }

  @Test func firefoxParsesTheExactDefaultFlagWithoutGuessingFromNames() throws {
    let root = URL(fileURLWithPath: "/Users/example/Firefox", isDirectory: true)
    let profiles = try FirefoxProfileParser.parse(
      text: """
        [Profile0]
        Name=Default-looking Name
        IsRelative=1
        Path=Profiles/ordinary
        [Profile1]
        Name=Work
        IsRelative=1
        Path=Profiles/work
        Default=1
        """,
      baseDirectory: root
    )

    #expect(profiles.first { $0.displayName == "Default-looking Name" }?.isDefault == false)
    #expect(profiles.first { $0.displayName == "Work" }?.isDefault == true)
  }

  @Test func firefoxIgnoresNonProfileSectionsAndAcceptsExactRelativeFlags() throws {
    let text = """
      [Profile0]
      Name=Valid
      IsRelative=1
      Path=Profiles/../Profiles/valid
      [ProfileWork]
      Name=Wrong Section
      IsRelative=1
      Path=Profiles/wrong
      [Profile2]
      Name=Absolute
      IsRelative=0
      Path=/Users/example/Firefox/Profiles/absolute
      """

    let profiles = try FirefoxProfileParser.parse(
      text: text,
      baseDirectory: URL(fileURLWithPath: "/Users/example/Firefox", isDirectory: true)
    )

    #expect(profiles.map(\.displayName) == ["Absolute", "Valid"])
    #expect(profiles.map(\.identifier).allSatisfy { $0.hasPrefix("firefox-profile-v1:") })
    #expect(
      profiles.compactMap(\.directoryURL?.path) == [
        "/Users/example/Firefox/Profiles/absolute",
        "/Users/example/Firefox/Profiles/valid",
      ])
  }

  @Test(
    arguments: [
      """
      [Profile0]
      IsRelative=1
      Path=Profiles/missing-name
      """,
      """
      [Profile0]
      Name=Missing Path
      IsRelative=1
      """,
      """
      [Profile0]
      Name=Missing Relative Flag
      Path=Profiles/missing-flag
      """,
      """
      [Profile0]
      Name=Invalid Relative Flag
      IsRelative=true
      Path=Profiles/invalid-flag
      """,
      """
      [Profile0]
      Name=Invalid Absolute Path
      IsRelative=0
      Path=Profiles/not-absolute
      """,
    ]
  )
  func firefoxRejectsEveryStructurallyMalformedNumericProfileSection(_ text: String) {
    do {
      _ = try FirefoxProfileParser.parse(
        text: text,
        baseDirectory: URL(fileURLWithPath: "/Users/private-user/Firefox", isDirectory: true)
      )
      Issue.record("Expected a sanitized malformed-profile parser error")
    } catch {
      #expect(error as? FirefoxProfileParserError == .malformedProfileSection)
      let description = String(describing: error)
      #expect(!description.contains("private-user"))
      #expect(!description.contains("Profiles/"))
    }
  }

  @Test func firefoxLegitimatelyEmptyProfilesDocumentIsValid() throws {
    let profiles = try FirefoxProfileParser.parse(
      text: """
        [General]
        StartWithLastProfile=1

        [Install308046B0AF4A39CB]
        Default=Profiles/default-release
        Locked=1
        """,
      baseDirectory: URL(fileURLWithPath: "/Users/example/Firefox", isDirectory: true)
    )

    #expect(profiles.isEmpty)
  }

  @Test func firefoxIdentifiersAreOpaqueDeterministicAndIndependentOfMutableName() throws {
    let root = URL(
      fileURLWithPath: "/Users/private-user/Library/Application Support/Firefox",
      isDirectory: true
    )
    let original = try FirefoxProfileParser.parse(
      text: """
        [Profile0]
        Name=Original Name
        IsRelative=1
        Path=Profiles/work.default-release
        """,
      baseDirectory: root
    )
    let renamed = try FirefoxProfileParser.parse(
      text: """
        [Profile0]
        Name=Renamed Profile
        IsRelative=1
        Path=Profiles/work.default-release
        """,
      baseDirectory: root
    )

    let originalProfile = try #require(original.first)
    let renamedProfile = try #require(renamed.first)
    #expect(originalProfile.identifier == renamedProfile.identifier)
    #expect(originalProfile.identifier.hasPrefix("firefox-profile-v1:"))
    #expect(!originalProfile.identifier.contains("/Users"))
    #expect(!originalProfile.identifier.contains("private-user"))
    #expect(!originalProfile.identifier.contains(root.path))
    #expect(!originalProfile.identifier.contains("work.default-release"))
    #expect(
      originalProfile.directoryURL?.path
        == "/Users/private-user/Library/Application Support/Firefox/Profiles/work.default-release"
    )
  }

  @Test func firefoxDuplicateNamesRemainDistinctWithoutLeakingEitherPath() throws {
    let root = URL(fileURLWithPath: "/Users/private-user/Firefox", isDirectory: true)
    let profiles = try FirefoxProfileParser.parse(
      text: """
        [Profile0]
        Name=Same Name
        IsRelative=1
        Path=Profiles/one
        [Profile1]
        Name=Same Name
        IsRelative=1
        Path=Profiles/two
        """,
      baseDirectory: root
    )

    #expect(profiles.count == 2)
    #expect(Set(profiles.map(\.identifier)).count == 2)
    #expect(profiles.allSatisfy { $0.identifier.hasPrefix("firefox-profile-v1:") })
    #expect(profiles.allSatisfy { !$0.identifier.contains(root.path) })
  }

  @Test func firefoxOpaqueIdentityValidationAcceptsOnlyLowercaseSHA256Hex() {
    let valid = FirefoxProfileIdentity.identifier(
      for: URL(fileURLWithPath: "/profiles/work", isDirectory: true)
    )

    #expect(FirefoxProfileIdentity.isOpaqueIdentifier(valid))
    #expect(
      !FirefoxProfileIdentity.isOpaqueIdentifier(
        FirefoxProfileIdentity.prefix + String(repeating: "٠", count: 64)
      ))
    #expect(
      !FirefoxProfileIdentity.isOpaqueIdentifier(
        FirefoxProfileIdentity.prefix + String(repeating: "A", count: 64)
      ))
  }
}

func fixtureData(_ name: String) throws -> Data {
  try Data(contentsOf: fixtureURL(name))
}

func fixtureText(_ name: String) throws -> String {
  try String(contentsOf: fixtureURL(name), encoding: .utf8)
}

func fixtureURL(_ name: String) -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appending(path: "Fixtures")
    .appending(path: name)
}
