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
          directoryURL: nil
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

  @Test func firefoxResolvesRelativeAndAbsolutePathsAndSkipsMalformedSections() throws {
    let baseDirectory = URL(fileURLWithPath: "/Users/example/Firefox", isDirectory: true)
    let profiles = try FirefoxProfileParser.parse(
      text: fixtureText("firefox-profiles.ini"),
      baseDirectory: baseDirectory
    )

    #expect(
      profiles == [
        DiscoveredProfile(
          identifier: "/Users/example/Firefox/Profiles/personal.default-release",
          displayName: "Personal",
          directoryURL: baseDirectory.appending(
            path: "Profiles/personal.default-release", directoryHint: .isDirectory),
          launchIdentifier: "Personal"
        ),
        DiscoveredProfile(
          identifier: "/Users/example/Firefox/Profiles/work",
          displayName: "Work",
          directoryURL: URL(
            fileURLWithPath: "/Users/example/Firefox/Profiles/work", isDirectory: true),
          launchIdentifier: "Work"
        ),
      ])
  }

  @Test func firefoxAcceptsOnlyNumericProfileSectionsAndExactRelativeFlags() throws {
    let text = """
      [Profile0]
      Name=Valid
      IsRelative=1
      Path=Profiles/../Profiles/valid
      [ProfileWork]
      Name=Wrong Section
      IsRelative=1
      Path=Profiles/wrong
      [Profile1]
      Name=Wrong Flag
      IsRelative=true
      Path=Profiles/wrong-flag
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
    #expect(
      profiles.map(\.identifier) == [
        "/Users/example/Firefox/Profiles/absolute",
        "/Users/example/Firefox/Profiles/valid",
      ])
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
