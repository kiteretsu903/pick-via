import AppKit
import PickViaCore
import SwiftUI
import XCTest

@testable import PickVia

@MainActor
final class ReadmeScreenshotCaptureTests: XCTestCase {
  func testBackdropPNGValidationRejectsNonRetinaDimensions() throws {
    let outputURL = FileManager.default.temporaryDirectory
      .appending(path: "pickvia-non-retina-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: outputURL) }

    let representation = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 768,
        pixelsHigh: 512,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    )
    let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
    try data.write(to: outputURL, options: .atomic)

    XCTAssertThrowsError(
      try validateCapturedPNG(
        at: outputURL,
        expectedPixelsWide: 1536,
        expectedPixelsHigh: 1024
      )
    ) { error in
      XCTAssertEqual(
        String(describing: error),
        "Captured PNG is 768x512 pixels; expected 1536x1024 pixels"
      )
    }
  }

  func testUnsupportedBackingScaleErrorIsClear() {
    XCTAssertEqual(
      ScreenshotCaptureError.unsupportedBackingScale(1).description,
      "WindowServer screenshot capture requires a 2x backing scale; got 1x"
    )
  }

  func testCaptureSyntheticReadmeScreenshots() throws {
    guard ProcessInfo.processInfo.environment["PICKVIA_CAPTURE_README_SCREENSHOTS"] == "1"
    else { throw XCTSkip("README screenshot capture is opt-in") }

    let fixture = ScreenshotFixture()
    let model = fixture.makeModel()
    try model.load()

    let repositoryScreenshotsDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "docs/screenshots", directoryHint: .isDirectory)
    let outputPath = try XCTUnwrap(
      ProcessInfo.processInfo.environment["PICKVIA_SCREENSHOT_OUTPUT_DIR"],
      "PICKVIA_SCREENSHOT_OUTPUT_DIR must be set to a review output directory"
    )
    guard !outputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw ScreenshotCaptureError.invalidOutputDirectory
    }
    let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
    try FileManager.default.createDirectory(
      at: outputDirectory,
      withIntermediateDirectories: true
    )

    try captureWindow(
      rootView: ScreenshotSettingsRoot()
        .environment(model),
      contentSize: NSSize(width: 1080, height: 790),
      title: "PickVia Settings",
      outputURL: outputDirectory.appending(path: "pickvia-settings@2x.png")
    )

    let browserPresentation = ChooserPresentation.make(
      request: RoutingRequest(
        kind: .web,
        url: URL(string: "https://example.com/projects/launch-plan")!
      ),
      applications: fixture.browserChooserApplications,
      targets: fixture.browserChooserTargets
    )
    try captureStandaloneView(
      ChooserView(
        presentation: browserPresentation,
        showsURL: true,
        density: .spacious,
        onSelection: { _ in },
        onCopyURL: {},
        onOpenSettings: { _ in },
        onCancel: {}
      ),
      outputURL: outputDirectory.appending(path: "pickvia-browser-chooser@2x.png")
    )

    let mailPresentation = ChooserPresentation.make(
      request: RoutingRequest(
        kind: .mail,
        url: URL(string: "mailto:hello@example.com?subject=Project%20update")!
      ),
      applications: fixture.mailApplications,
      targets: fixture.mailTargets
    )
    try captureStandaloneView(
      ChooserView(
        presentation: mailPresentation,
        showsURL: false,
        density: .spacious,
        onSelection: { _ in },
        onCopyURL: {},
        onOpenSettings: { _ in },
        onCancel: {}
      ),
      outputURL: outputDirectory.appending(path: "pickvia-mail-chooser@2x.png")
    )

    let backdropURL = repositoryScreenshotsDirectory.appending(path: "pickvia-chooser-backdrop.png")
    let backdrop = try XCTUnwrap(NSImage(contentsOf: backdropURL))
    try captureBackdropWindow(
      ZStack {
        Image(nsImage: backdrop)
          .resizable()
          .scaledToFill()
        ChooserView(
          presentation: browserPresentation,
          showsURL: true,
          density: .compact,
          onSelection: { _ in },
          onCopyURL: {},
          onOpenSettings: { _ in },
          onCancel: {}
        )
        .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
      }
      .frame(width: 768, height: 512)
      .clipped(),
      outputURL: outputDirectory.appending(path: "pickvia-browser-chooser-backdrop@2x.png")
    )
    try captureBackdropWindow(
      ZStack {
        Image(nsImage: backdrop)
          .resizable()
          .scaledToFill()
        ChooserView(
          presentation: mailPresentation,
          showsURL: false,
          density: .spacious,
          onSelection: { _ in },
          onCopyURL: {},
          onOpenSettings: { _ in },
          onCancel: {}
        )
        .shadow(color: .black.opacity(0.3), radius: 22, y: 12)
      }
      .frame(width: 768, height: 512)
      .clipped(),
      outputURL: outputDirectory.appending(path: "pickvia-mail-chooser-backdrop@2x.png")
    )
  }

  private func captureWindow<Content: View>(
    rootView: Content,
    contentSize: NSSize,
    title: String,
    outputURL: URL
  ) throws {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: contentSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = title
    window.contentView = NSHostingView(rootView: rootView)
    window.setContentSize(contentSize)
    window.center()
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    NSApp.activate(ignoringOtherApps: true)
    pumpMainRunLoop()
    window.title = title
    pumpMainRunLoop()
    guard window.backingScaleFactor == 2 else {
      throw ScreenshotCaptureError.unsupportedBackingScale(window.backingScaleFactor)
    }

    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l" + String(window.windowNumber), outputURL.path]
    try capture.run()
    capture.waitUntilExit()
    guard capture.terminationStatus == 0 else {
      throw ScreenshotCaptureError.screencaptureFailed(capture.terminationStatus)
    }
  }

  private func captureStandaloneView<Content: View>(
    _ rootView: Content,
    outputURL: URL
  ) throws {
    let hostingView = NSHostingView(rootView: rootView)
    let fittingSize = hostingView.fittingSize
    hostingView.frame = NSRect(origin: .zero, size: fittingSize)

    let panel = NSPanel(
      contentRect: hostingView.bounds,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.contentView = hostingView
    panel.orderFrontRegardless()
    defer { panel.orderOut(nil) }
    pumpMainRunLoop()

    try writePNG(of: hostingView, to: outputURL)
  }

  private func captureBackdropWindow<Content: View>(
    _ rootView: Content,
    outputURL: URL
  ) throws {
    let contentSize = NSSize(width: 768, height: 512)
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: contentSize)

    let window = NSWindow(
      contentRect: hostingView.bounds,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isOpaque = true
    window.backgroundColor = .black
    window.contentView = hostingView
    window.center()
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil) }
    NSApp.activate(ignoringOtherApps: true)
    pumpMainRunLoop()
    guard window.backingScaleFactor == 2 else {
      throw ScreenshotCaptureError.unsupportedBackingScale(window.backingScaleFactor)
    }

    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l" + String(window.windowNumber), outputURL.path]
    try capture.run()
    capture.waitUntilExit()
    guard capture.terminationStatus == 0 else {
      throw ScreenshotCaptureError.screencaptureFailed(capture.terminationStatus)
    }
    try validateCapturedPNG(
      at: outputURL,
      expectedPixelsWide: 1536,
      expectedPixelsHigh: 1024
    )
  }

  private func validateCapturedPNG(
    at outputURL: URL,
    expectedPixelsWide: Int,
    expectedPixelsHigh: Int
  ) throws {
    let data: Data
    do {
      data = try Data(contentsOf: outputURL)
    } catch {
      throw ScreenshotCaptureError.capturedPNGUnreadable(outputURL, error.localizedDescription)
    }
    guard let representation = NSBitmapImageRep(data: data) else {
      throw ScreenshotCaptureError.capturedPNGUnreadable(
        outputURL,
        "the file is not a decodable PNG"
      )
    }
    guard
      representation.pixelsWide == expectedPixelsWide,
      representation.pixelsHigh == expectedPixelsHigh
    else {
      throw ScreenshotCaptureError.unexpectedPNGDimensions(
        actualWidth: representation.pixelsWide,
        actualHeight: representation.pixelsHigh,
        expectedWidth: expectedPixelsWide,
        expectedHeight: expectedPixelsHigh
      )
    }
  }

  private func writePNG(of view: NSView, to outputURL: URL) throws {
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds
    let scale: CGFloat = 2
    guard
      let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(bounds.width * scale),
        pixelsHigh: Int(bounds.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
      )
    else {
      throw ScreenshotCaptureError.bitmapAllocationFailed
    }
    representation.size = bounds.size
    view.cacheDisplay(in: bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw ScreenshotCaptureError.pngEncodingFailed
    }
    try data.write(to: outputURL, options: .atomic)
  }

  private func pumpMainRunLoop() {
    let deadline = Date().addingTimeInterval(0.4)
    while Date() < deadline {
      RunLoop.main.run(mode: .default, before: deadline)
    }
  }
}

private enum ScreenshotCaptureError: Error, CustomStringConvertible {
  case invalidOutputDirectory
  case unsupportedBackingScale(CGFloat)
  case screencaptureFailed(Int32)
  case capturedPNGUnreadable(URL, String)
  case unexpectedPNGDimensions(
    actualWidth: Int,
    actualHeight: Int,
    expectedWidth: Int,
    expectedHeight: Int
  )
  case bitmapAllocationFailed
  case pngEncodingFailed

  var description: String {
    switch self {
    case .invalidOutputDirectory:
      return "PICKVIA_SCREENSHOT_OUTPUT_DIR must not be empty"
    case .unsupportedBackingScale(let scale):
      let renderedScale = String(format: "%g", Double(scale))
      return "WindowServer screenshot capture requires a 2x backing scale; got \(renderedScale)x"
    case .screencaptureFailed(let status):
      return "screencapture exited with status \(status)"
    case .capturedPNGUnreadable(let url, let reason):
      return "Could not read captured PNG at \(url.path): \(reason)"
    case .unexpectedPNGDimensions(
      let actualWidth,
      let actualHeight,
      let expectedWidth,
      let expectedHeight
    ):
      let actual = "\(actualWidth)x\(actualHeight)"
      let expected = "\(expectedWidth)x\(expectedHeight)"
      return "Captured PNG is \(actual) pixels; expected \(expected) pixels"
    case .bitmapAllocationFailed:
      return "Could not allocate a Retina bitmap"
    case .pngEncodingFailed:
      return "Could not encode PNG"
    }
  }
}

private struct ScreenshotSettingsRoot: View {
  @State private var selection: SettingsDestination? = .browsers

  var body: some View {
    HStack(spacing: 0) {
      List(SettingsDestination.allCases, selection: $selection) { destination in
        Label(destination.title, systemImage: destination.systemImage)
          .tag(destination)
      }
      .frame(width: 180)

      Divider()
      BrowserSettingsView()
    }
    .frame(minWidth: 720, minHeight: 480)
  }
}

private struct ScreenshotFixture {
  let applications: [RoutedApplication]
  let settingsTargets: [RouteTarget]
  let browserChooserApplications: [RoutedApplication]
  let browserChooserTargets: [RouteTarget]
  let mailApplications: [RoutedApplication]
  let mailTargets: [RouteTarget]

  @MainActor init() {
    let safari = Self.browser(
      "com.apple.Safari",
      name: "Safari",
      family: .safari,
      path: "/Applications/Safari.app"
    )
    let chrome = Self.browser(
      "com.google.Chrome",
      name: "Google Chrome",
      family: .chromium,
      path: "/Applications/Google Chrome.app"
    )
    let chromium = Self.browser(
      "org.chromium.Chromium",
      name: "Chromium",
      family: .chromium,
      path: "/Applications/Chromium.app"
    )
    let edge = Self.browser(
      "com.microsoft.edgemac",
      name: "Microsoft Edge",
      family: .chromium,
      path: "/Applications/Microsoft Edge.app"
    )
    let brave = Self.browser(
      "com.brave.Browser",
      name: "Brave Browser",
      family: .chromium,
      path: "/Applications/Brave Browser.app"
    )
    let vivaldi = Self.browser(
      "com.vivaldi.Vivaldi",
      name: "Vivaldi",
      family: .chromium,
      path: "/Applications/Vivaldi.app"
    )
    let firefox = Self.browser(
      "org.mozilla.firefox",
      name: "Firefox",
      family: .firefox,
      path: "/Applications/Firefox.app"
    )

    let appleMail = Self.mail(
      "com.apple.mail",
      name: "Mail",
      path: "/System/Applications/Mail.app"
    )
    let outlook = Self.mail(
      "com.microsoft.Outlook",
      name: "Microsoft Outlook",
      path: "/Applications/Microsoft Outlook.app"
    )
    let thunderbird = Self.mail(
      "org.mozilla.thunderbird",
      name: "Thunderbird",
      path: "/Applications/Thunderbird.app"
    )
    let openIn = Self.mail(
      "app.loshadki.OpenIn",
      name: "OpenIn",
      path: NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "app.loshadki.OpenIn"
      )?.path ?? "/Applications/OpenIn.app"
    )
    let zoom = Self.mail(
      "us.zoom.xos",
      name: "zoom.us",
      path: "/Applications/zoom.us.app"
    )

    let browsers = [safari, chrome, chromium, edge, brave, vivaldi, firefox]
    mailApplications = [appleMail, outlook, openIn, thunderbird, zoom]
    applications = browsers + mailApplications

    let samples: [(RoutedApplication, String, String?)] = [
      (chrome, "Client Work", "Work"),
      (chromium, "Experiments", "Lab"),
      (edge, "Team", "Organization"),
      (brave, "Personal", "Personal"),
      (vivaldi, "Projects", "Projects"),
      (firefox, "Research Lab", "Research"),
      (safari, "Default", nil),
    ]
    settingsTargets = samples.enumerated().map { index, sample in
      Self.browserTarget(
        application: sample.0,
        label: sample.1,
        profile: sample.2,
        mode: .normal,
        order: index
      )
    }

    browserChooserApplications = [chrome, brave, firefox, safari]
    browserChooserTargets = [
      Self.browserTarget(
        application: chrome, label: "Personal", profile: "Personal", mode: .normal, order: 0),
      Self.browserTarget(
        application: chrome, label: "School", profile: "School", mode: .normal, order: 1),
      Self.browserTarget(
        application: chrome, label: "Work", profile: "Work", mode: .normal, order: 2),
      Self.browserTarget(
        application: brave, label: "Default", profile: nil, mode: .normal, order: 3),
      Self.browserTarget(
        application: brave, label: "Private", profile: nil, mode: .private, order: 4),
      Self.browserTarget(
        application: firefox, label: "Research", profile: "Research", mode: .normal, order: 5),
      Self.browserTarget(
        application: firefox, label: "Research Private", profile: "Research", mode: .private,
        order: 6),
      Self.browserTarget(
        application: safari, label: "Safari", profile: nil, mode: .normal, order: 7),
    ]
    mailTargets = mailApplications.enumerated().map { index, application in
      RouteTarget(
        id: RouteTarget.mailID(bundleIdentifier: application.bundleIdentifier),
        applicationID: application.id,
        label: application.displayName,
        isEnabled: true,
        sortOrder: index,
        origin: .detected,
        availability: .available,
        capability: .mail
      )
    }
  }

  @MainActor
  func makeModel() -> AppModel {
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: applications,
      targets: settingsTargets + mailTargets
    )
    return AppModel(
      configStore: ScreenshotConfigStore(config: config),
      browserCatalog: ScreenshotBrowserCatalog(config: config),
      mailCatalog: ScreenshotMailCatalog(config: config),
      preferences: ScreenshotPreferences(),
      defaultBrowser: ScreenshotDefaultHandler(),
      loginItem: ScreenshotLoginItem(),
      routing: ScreenshotRouting()
    )
  }

  private static func browser(
    _ bundleIdentifier: String,
    name: String,
    family: BrowserFamily,
    path: String
  ) -> RoutedApplication {
    RoutedApplication(
      id: bundleIdentifier,
      family: family,
      displayName: name,
      bundleIdentifier: bundleIdentifier,
      applicationURL: URL(fileURLWithPath: path),
      executableURL: nil,
      isAvailable: true
    )
  }

  private static func mail(
    _ bundleIdentifier: String,
    name: String,
    path: String
  ) -> RoutedApplication {
    RoutedApplication(
      id: bundleIdentifier,
      displayName: name,
      bundleIdentifier: bundleIdentifier,
      capabilities: [.mail(isAvailable: true)],
      applicationURL: URL(fileURLWithPath: path)
    )
  }

  private static func browserTarget(
    application: RoutedApplication,
    label: String,
    profile: String?,
    mode: BrowserMode,
    order: Int
  ) -> RouteTarget {
    let identity =
      application.family == .firefox && profile != nil
      ? "firefox-profile-v1:64c1b2743b8f168cd1847de57912d041fe0b5dba870ac27bb9750a46ba689e7a"
      : profile
    return RouteTarget(
      id: BrowserCatalog.targetID(
        bundleIdentifier: application.bundleIdentifier,
        profileIdentifier: identity,
        mode: mode
      ),
      browserID: application.id,
      label: label,
      profileIdentifier: profile,
      profileDisplayName: profile,
      profileIdentity: identity,
      mode: mode,
      isEnabled: true,
      sortOrder: order,
      origin: .detected,
      availability: .available
    )
  }
}

private struct ScreenshotConfigStore: ConfigStoring {
  let config: PickViaConfig
  func load() throws -> PickViaConfig { config }
  func loadOutcome() -> ConfigLoadOutcome { .loaded(config) }
  func save(_ config: PickViaConfig) throws {}
}

private struct ScreenshotBrowserCatalog: BrowserDiscovering {
  let config: PickViaConfig
  func scan() throws -> [DiscoveredBrowser] { [] }
  func scanResult() -> BrowserScanResult {
    BrowserScanResult(browsers: [], warnings: [], isAuthoritative: true)
  }
  func reconcile(discovered: [DiscoveredBrowser], with config: PickViaConfig) -> PickViaConfig {
    self.config
  }
}

private struct ScreenshotMailCatalog: MailDiscovering {
  let config: PickViaConfig
  func scanResult() -> MailScanResult {
    MailScanResult(applications: [], isAuthoritative: true)
  }
  func reconcile(_ scan: MailScanResult, with config: PickViaConfig) -> PickViaConfig {
    self.config
  }
  func runtimeSanitizedFallback(_ config: PickViaConfig) -> PickViaConfig { config }
}

@MainActor
private final class ScreenshotPreferences: PreferencesStoring {
  func bool(forKey key: String) -> Bool? { nil }
  func integer(forKey key: String) -> Int? { 3 }
  func set(_ value: Bool, forKey key: String) {}
  func set(_ value: Int, forKey key: String) {}
}

@MainActor
private final class ScreenshotDefaultHandler: DefaultHandlerServicing {
  func status() -> DefaultHandlerStatus {
    DefaultHandlerStatus(http: .isDefault, https: .isDefault, mailto: .isDefault)
  }
  func requestDefault(for schemes: [String]) async throws {}
}

@MainActor
private final class ScreenshotLoginItem: LoginItemServicing {
  var isEnabled: Bool { true }
  func setEnabled(_ enabled: Bool) throws {}
}

@MainActor
private final class ScreenshotRouting: AppRouting {
  func accept(_ url: URL) {}
  func preview(_ url: URL) {}
}
