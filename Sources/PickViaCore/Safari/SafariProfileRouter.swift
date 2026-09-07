import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Safari's AX identifiers are an observed implementation detail, not a public profile API.
/// Unknown layouts are intentionally rejected. Labels are never used as selectors.
public struct SafariProfileMenuItem: Codable, Equatable, Sendable {
  public let identifier: String
  public let name: String

  public init?(identifier: String) {
    let parts = identifier.components(separatedBy: "?isDefaultProfile=")
    guard parts.count == 2, ["true", "false"].contains(parts[1]),
      parts[0].hasPrefix("New"), parts[0].hasSuffix("Window")
    else { return nil }
    let name = String(parts[0].dropFirst(3).dropLast(6))
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    self.identifier = identifier
    self.name = name
  }

  public static func unique(_ identifiers: [String]) throws -> [Self] {
    let items = identifiers.compactMap(Self.init(identifier:))
    guard !items.isEmpty,
      Set(items.map(\.identifier)).count == items.count,
      Set(items.map(\.name)).count == items.count
    else { throw SafariProfileError.ambiguousMenu }
    return items
  }

  public func matchesWindowProfile(identifier: String) -> Bool {
    // Match the entire profile component, never a substring or a page title.
    let prefix = "TabGroupPickerButton?Profile="
    guard identifier.hasPrefix(prefix),
      let suffix = identifier.range(of: "&Icon=", options: .backwards)
    else { return false }
    return String(
      identifier[
        identifier.index(identifier.startIndex, offsetBy: prefix.count)..<suffix.lowerBound])
      == name
  }
}

public struct SafariProfilePreferences: Sendable {
  public static let enabledKey = "safariProfilesEnabled"
  private static let cacheKey = "safariProfileMenuIdentifiers"
  public init() {}
  public var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
  public var discoveredProfiles: [DiscoveredProfile] {
    guard isEnabled, AXIsProcessTrusted(),
      let identifiers = UserDefaults.standard.stringArray(forKey: Self.cacheKey),
      let items = try? SafariProfileMenuItem.unique(identifiers)
    else { return [] }
    return items.map {
      DiscoveredProfile(identifier: $0.identifier, displayName: $0.name, directoryURL: nil)
    }
  }
  public func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
  }
  public func save(_ items: [SafariProfileMenuItem]) {
    UserDefaults.standard.set(items.map(\.identifier), forKey: Self.cacheKey)
  }
}

public enum MacOSControlPermission {
  public static var name: String {
    name(majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
  }

  static func name(majorVersion: Int) -> String {
    majorVersion >= 27 ? "Device Control and Data Access" : "Accessibility"
  }
}

public enum SafariProfileError: LocalizedError {
  case disabled, accessibilityRequired, automationRequired, ambiguousMenu, windowNotVerified, busy
  public var errorDescription: String? {
    switch self {
    case .disabled: "Enable Safari profiles in PickVia’s Browser settings first."
    case .accessibilityRequired:
      (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        ? "Allow PickVia in System Settings → Privacy & Security → Device Control and Data Access, then refresh Safari profiles."
        : "Allow PickVia in System Settings → Privacy & Security → Accessibility, then refresh Safari profiles.")
    case .automationRequired:
      "Allow PickVia to control Safari in System Settings → Privacy & Security → Automation, then retry."
    case .ambiguousMenu:
      "Safari’s profile menu could not be identified uniquely. Refresh profiles in Browser settings. No link was opened."
    case .windowNotVerified:
      "The new Safari profile window could not be verified. No link was sent to another window."
    case .busy: "Another Safari profile operation is in progress. Please retry."
    }
  }
}

@MainActor
public final class SafariProfileRouter {
  public static let shared = SafariProfileRouter()
  private var isBusy = false
  private let logger = Logger(subsystem: "dev.bozhenpeng.PickVia", category: "SafariProfiles")
  private init() {}

  public static var accessibilityGranted: Bool { AXIsProcessTrusted() }

  public func refresh() async throws -> [SafariProfileMenuItem] {
    guard !isBusy else { throw SafariProfileError.busy }
    isBusy = true
    defer { isBusy = false }
    guard AXIsProcessTrusted() else { throw SafariProfileError.accessibilityRequired }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
    else { throw SafariProfileError.windowNotVerified }
    let app = try await safari(at: url)
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 1)
    let elements = try await profileMenu(in: ax)
    let items = try SafariProfileMenuItem.unique(
      elements.compactMap { string($0, kAXIdentifierAttribute) })
    SafariProfilePreferences().save(items)
    return items
  }

  public func open(url: URL, applicationURL: URL, menuIdentifier: String) async throws -> Int32 {
    guard !isBusy else { throw SafariProfileError.busy }
    isBusy = true
    defer { isBusy = false }
    guard SafariProfilePreferences().isEnabled else { throw SafariProfileError.disabled }
    guard AXIsProcessTrusted() else { throw SafariProfileError.accessibilityRequired }
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      let profile = SafariProfileMenuItem(identifier: menuIdentifier)
    else { throw SafariProfileError.ambiguousMenu }
    let app = try await safari(at: applicationURL)
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 1)
    let menu = try await profileMenu(in: ax)
    _ = try SafariProfileMenuItem.unique(menu.compactMap { string($0, kAXIdentifierAttribute) })
    let matches = menu.filter { string($0, kAXIdentifierAttribute) == menuIdentifier }
    guard matches.count == 1, (attribute(matches[0], kAXEnabledAttribute) as? Bool) == true
    else { throw SafariProfileError.ambiguousMenu }
    // Ask for Automation before making a window. No URL appears in the permission probe.
    logger.notice("Reading initial Safari window IDs")
    let events = SafariProfileAppleEvents(processIdentifier: app.processIdentifier)
    let oldIDs = try await events.windowIDs()
    let oldWindows = elements(ax, kAXWindowsAttribute)
    logger.notice("Pressing Safari profile menu action")
    guard AXUIElementPerformAction(matches[0], kAXPressAction as CFString) == .success
    else { throw SafariProfileError.ambiguousMenu }

    for _ in 0..<80 {
      try await Task.sleep(for: .milliseconds(75))
      guard !app.isTerminated else { throw SafariProfileError.windowNotVerified }
      let windows = elements(ax, kAXWindowsAttribute)
      let added = windows.filter { item in !oldWindows.contains { CFEqual($0, item) } }
      let ids = try await events.windowIDs()
      let addedIDs = ids.subtracting(oldIDs)
      guard added.count <= 1, addedIDs.count <= 1 else {
        throw SafariProfileError.windowNotVerified
      }
      guard added.count == 1, addedIDs.count == 1 else { continue }
      // Read only the toolbar, never webpage content (which can imitate UI labels).
      let toolbars = elements(added[0], kAXChildrenAttribute).filter {
        string($0, kAXRoleAttribute) == kAXToolbarRole
      }
      let profileButtons = toolbars.flatMap { descendants($0, depth: 4) }.compactMap {
        string($0, kAXIdentifierAttribute)
      }.filter { $0.hasPrefix("TabGroupPickerButton?Profile=") }
      guard profileButtons.count == 1,
        profile.matchesWindowProfile(identifier: profileButtons[0])
      else { continue }
      guard let id = addedIDs.first, !app.isTerminated else {
        throw SafariProfileError.windowNotVerified
      }
      let idsAreStable = try await events.windowIDs() == ids
      let currentWindowCount = elements(ax, kAXWindowsAttribute).count
      guard idsAreStable, currentWindowCount == windows.count else {
        logger.debug("Waiting for Safari window creation to settle")
        continue
      }
      logger.notice("Delivering URL to the verified new Safari window")
      // Explicit window ID, no front-window command, clipboard, or global keystrokes.
      try await events.open(url: url, windowID: id)
      return app.processIdentifier
    }
    throw SafariProfileError.windowNotVerified
  }

  private func safari(at url: URL) async throws -> NSRunningApplication {
    guard Bundle(url: url)?.bundleIdentifier == "com.apple.Safari" else {
      throw SafariProfileError.windowNotVerified
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    guard app.bundleIdentifier == "com.apple.Safari",
      app.bundleURL?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
    else { throw SafariProfileError.windowNotVerified }
    return app
  }

  private func profileMenu(in app: AXUIElement) async throws -> [AXUIElement] {
    for _ in 0..<40 {
      if let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() {
        let menuBar = unsafeDowncast(bar, to: AXUIElement.self)
        let all = descendants(menuBar, depth: 5)
        if let fileMenu = all.first(where: {
          string($0, kAXIdentifierAttribute) == "SafariFileMenu"
        }) {
          let items = descendants(fileMenu, depth: 3).filter {
            SafariProfileMenuItem(identifier: string($0, kAXIdentifierAttribute) ?? "") != nil
          }
          if !items.isEmpty { return items }
        }
      }
      try await Task.sleep(for: .milliseconds(75))
    }
    throw SafariProfileError.ambiguousMenu
  }

  private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
      return nil
    }
    return value
  }
  private func string(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
  }
  private func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
    attribute(element, name) as? [AXUIElement] ?? []
  }
  private func descendants(_ element: AXUIElement, depth: Int) -> [AXUIElement] {
    guard depth > 0 else { return [] }
    let children = elements(element, kAXChildrenAttribute)
    return children + children.flatMap { descendants($0, depth: depth - 1) }
  }
}
