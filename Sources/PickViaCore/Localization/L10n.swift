import Foundation

public struct AppLanguage: Codable, Identifiable, Sendable, Equatable {
  public let code: String
  public let name: String
  public let dir: String
  public var id: String { code }
  public var isRightToLeft: Bool { dir == "rtl" }
}

/// App language is independent of macOS's language. System mode follows only the
/// primary preference: an unsupported primary must not select a secondary language.
public enum L10n {
  public static let preferenceKey = "appLanguage"
  public static let system = "system"
  private static let resourceBundle: Bundle = {
    if let url = Bundle.main.resourceURL?.appendingPathComponent("PickVia_PickViaCore.bundle"),
      let bundle = Bundle(url: url)
    {
      return bundle
    }
    return Bundle.module
  }()
  public static let languages: [AppLanguage] = {
    guard let url = resourceBundle.url(forResource: "locales", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let result = try? JSONDecoder().decode([AppLanguage].self, from: data)
    else { return [] }
    return result
  }()
  private static let bundles: [String: Bundle] = Dictionary(
    uniqueKeysWithValues: languages.compactMap { language in
      guard
        let path = resourceBundle.path(forResource: language.code, ofType: "lproj")
          ?? resourceBundle.path(forResource: language.code.lowercased(), ofType: "lproj"),
        let bundle = Bundle(path: path)
      else { return nil }
      return (language.code, bundle)
    }
  )

  public static var currentCode: String {
    resolve(
      selection: UserDefaults.standard.string(forKey: preferenceKey) ?? system,
      preferredLanguages: Locale.preferredLanguages)
  }

  public static func resolve(selection: String, preferredLanguages: [String]) -> String {
    let requested = selection == system ? (preferredLanguages.first ?? "en") : selection
    return match(requested)
  }

  public static func match(_ identifier: String) -> String {
    // Stop at BCP 47 extension singletons so extension values are never scripts.
    let raw = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-")
    var parts: [String] = []
    for part in raw {
      if part.count == 1 { break }
      parts.append(String(part))
    }
    guard let first = parts.first else { return "en" }
    let aliases = ["no": "nb", "tl": "fil", "iw": "he", "in": "id"]
    let language = aliases[first.lowercased()] ?? first.lowercased()
    let script = parts.dropFirst().first { $0.count == 4 }?.lowercased()
    let region = parts.dropFirst().first { $0.count == 2 || $0.count == 3 }?.uppercased()
    let supported = Set(languages.map(\.code))
    if language == "zh" {
      if let script, !["hans", "hant"].contains(script) { return "en" }
      if script == "hant" { return "zh-Hant" }
      if script == "hans" { return "zh-Hans" }
      return ["TW", "HK", "MO"].contains(region ?? "") ? "zh-Hant" : "zh-Hans"
    }
    if language == "pt" {
      guard script == nil || script == "latn" else { return "en" }
      return region == "BR" ? "pt-BR" : "pt-PT"
    }
    if let script {
      let candidate = language + "-" + script.prefix(1).uppercased() + script.dropFirst()
      if supported.contains(candidate) { return candidate }
      // Do not silently override an explicitly unsupported script.
      let nonLatinScripts = [
        "ja": "jpan", "ko": "kore", "ru": "cyrl", "ar": "arab", "hi": "deva",
        "bg": "cyrl", "uk": "cyrl", "sr": "cyrl", "mk": "cyrl", "el": "grek",
        "he": "hebr", "fa": "arab", "ur": "arab", "bn": "beng", "ta": "taml",
        "te": "telu", "mr": "deva", "gu": "gujr", "kn": "knda", "ml": "mlym",
        "pa": "guru", "ne": "deva", "si": "sinh", "th": "thai", "km": "khmr",
        "lo": "laoo", "my": "mymr", "mn": "cyrl", "ka": "geor", "hy": "armn",
        "kk": "cyrl", "am": "ethi",
      ]
      if script != (nonLatinScripts[language] ?? "latn") { return "en" }
    }
    if supported.contains(language) { return language }
    let normalized = parts.joined(separator: "-")
    return supported.first { $0.caseInsensitiveCompare(normalized) == .orderedSame } ?? "en"
  }

  public static func isRightToLeft(_ code: String) -> Bool {
    languages.first { $0.code == code }?.isRightToLeft ?? false
  }

  public static func tr(_ key: String, _ arguments: String...) -> String {
    translate(key, arguments: arguments, locale: currentCode)
  }

  public static func translate(_ key: String, arguments: [String] = [], locale: String) -> String {
    let fallback = bundles["en"]?.localizedString(forKey: key, value: key, table: nil) ?? key
    let template =
      bundles[locale]?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
    return interpolate(template, arguments: arguments)
  }

  /// One-pass interpolation: braces inside user-controlled names are literal.
  public static func interpolate(_ template: String, arguments: [String]) -> String {
    guard let pattern = try? NSRegularExpression(pattern: #"\{([0-9]+)\}"#) else { return template }
    let source = template as NSString
    let matches = pattern.matches(in: template, range: NSRange(location: 0, length: source.length))
    var result = ""
    var position = 0
    for match in matches {
      result += source.substring(
        with: NSRange(location: position, length: match.range.location - position))
      if let index = Int(source.substring(with: match.range(at: 1))),
        arguments.indices.contains(index)
      {
        result += arguments[index]
      } else {
        result += source.substring(with: match.range)
      }
      position = NSMaxRange(match.range)
    }
    result += source.substring(from: position)
    return result
  }
}
