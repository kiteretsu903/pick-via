import Foundation

/// Firefox writes LastPlatformDir in the profile's compatibility.ini.
/// This is a last-used association, not an ownership or launch-security check.
enum FirefoxProfileAssociation {
  static func applicationURL(data: Data) -> URL? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    var inCompatibility = false
    var paths: [String] = []
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("[") {
        inCompatibility = line == "[Compatibility]"
      } else if inCompatibility, line.hasPrefix("LastPlatformDir=") {
        paths.append(String(line.dropFirst("LastPlatformDir=".count)))
      }
    }
    guard paths.count == 1, let path = paths.first,
      (path as NSString).isAbsolutePath,
      path.hasSuffix(".app/Contents/Resources")
    else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
      .deletingLastPathComponent().deletingLastPathComponent()
  }
}
