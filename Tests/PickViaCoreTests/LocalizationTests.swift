import Foundation
import Testing

@testable import PickViaCore

@Suite("Localization runtime")
struct LocalizationTests {
  @Test func registryHasEightyUniqueAutonymsAndFourRTLLanguages() {
    #expect(L10n.languages.count == 80)
    #expect(Set(L10n.languages.map(\.code)).count == 80)
    #expect(L10n.languages.allSatisfy { !$0.name.isEmpty })
    #expect(Set(L10n.languages.filter(\.isRightToLeft).map(\.code)) == ["ar", "he", "fa", "ur"])
  }

  @Test func explicitSelectionWinsAndSystemUsesPrimaryOnly() {
    #expect(L10n.resolve(selection: "ja", preferredLanguages: ["de-DE"]) == "ja")
    #expect(L10n.resolve(selection: "system", preferredLanguages: ["de-DE", "fr"]) == "de")
    #expect(L10n.resolve(selection: "system", preferredLanguages: ["xx-ZZ", "ja"]) == "en")
    #expect(L10n.resolve(selection: "system", preferredLanguages: []) == "en")
  }

  @Test(arguments: [
    ("no-NO", "nb"), ("tl-PH", "fil"), ("iw-IL", "he"), ("in-ID", "id"),
    ("zh-Hant-CN", "zh-Hant"), ("zh-Hans-TW", "zh-Hans"), ("zh-HK", "zh-Hant"),
    ("zh-Latn-TW", "en"), ("zh-TW-u-ca-hans", "zh-Hant"),
    ("pt-BR", "pt-BR"), ("pt", "pt-PT"), ("pt-Latn-BR", "pt-BR"), ("pt-Cyrl-BR", "en"),
    ("sr-Cyrl", "sr"), ("sr-Latn", "en"), ("uz-Latn", "uz"), ("uz-Cyrl", "en"),
    ("mn-Cyrl", "mn"), ("mn-Mong", "en"), ("pa-Guru", "pa"), ("pa-Arab", "en"),
    ("az-Latn", "az"), ("az-Arab", "en"), ("kk-Cyrl", "kk"), ("kk-Latn", "en"),
    ("de_DE_u_co_phonebk", "de"), ("fr-Arab", "en"),
  ])
  func aliasesScriptsAndExtensions(pair: (String, String)) {
    #expect(L10n.match(pair.0) == pair.1)
  }

  @Test func interpolationDoesNotRecursivelyInterpretUserNames() {
    #expect(
      L10n.interpolate("{1} / {0}", arguments: ["name {1}", "second"]) == "second / name {1}")
    #expect(L10n.interpolate("{0} {4}", arguments: ["📚"]) == "📚 {4}")
  }

  @Test func nativeResourceTablesLoadTranslatedValues() {
    #expect(L10n.translate("Language", locale: "de") == "Sprache")
    #expect(L10n.translate("Language", locale: "zh-Hans") == "语言")
    #expect(L10n.translate("Language", locale: "ar") == "اللغة")
  }

  // Exercises Foundation's native .strings loading for every locale, including
  // script/region resource names that SwiftPM lowercases during packaging.
  @Test func allNativeTablesMatchReviewedCatalogs() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for language in L10n.languages {
      let url = root.appendingPathComponent("Localization/app/\(language.code).json")
      let expected = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
      for (key, value) in expected {
        #expect(L10n.translate(key, locale: language.code) == value)
      }
    }
  }

  @Test func fallback() {
    #expect(L10n.translate("Missing", locale: "unsupported") == "Missing")
    #expect(
      L10n.translate("Version {0} ({1})", arguments: ["1.4", "5"], locale: "en")
        == "Version 1.4 (5)")
    #expect(
      L10n.translate("Unknown external detail", locale: "unsupported") == "Unknown external detail")
  }
}
