import Foundation
import Testing

@testable import PickViaCore

struct MailCatalogTests {
  @Test func scanNormalizesLookupURLsAndFiltersInvalidDuplicateAndSelfApplications() throws {
    try withTemporaryApplications { root in
      let alpha = try application(
        at: root.appending(path: "Alpha.app"),
        bundleIdentifier: "com.example.alpha",
        displayName: "alpha"
      )
      let zulu = try application(
        at: root.appending(path: "Zulu.app"),
        bundleIdentifier: "com.example.zulu",
        displayName: "Zulu"
      )
      let selfApplication = try application(
        at: root.appending(path: "PickVia.app"),
        bundleIdentifier: "com.example.pickvia",
        displayName: "PickVia"
      )
      let blankIdentifier = try application(
        at: root.appending(path: "Blank.app"),
        bundleIdentifier: "   ",
        displayName: "Blank"
      )
      let bundle = try application(
        at: root.appending(path: "NotAnApplication.bundle"),
        bundleIdentifier: "com.example.bundle",
        displayName: "Not An Application"
      )
      let locator = MailApplicationLocatorStub(
        urls: [
          alpha.deletingLastPathComponent().appending(path: ".").appending(path: "Alpha.app"),
          alpha,
          selfApplication,
          blankIdentifier,
          bundle,
          root.appending(path: "not-an-app.txt"),
          zulu,
        ]
      )
      let catalog = MailCatalog(
        applicationLocator: locator,
        pickViaBundleIdentifier: "com.example.pickvia"
      )

      let result = catalog.scanResult()

      #expect(result.isAuthoritative)
      #expect(result.applications.map(\.bundleIdentifier) == ["com.example.alpha", "com.example.zulu"])
      #expect(result.applications.map(\.displayName) == ["alpha", "Zulu"])
      #expect(result.applications.first?.applicationURL == alpha.standardizedFileURL)
      #expect(locator.requestedURLs == [URL(string: "mailto:pickvia-discovery@invalid")!])
    }
  }

  @Test func scanFailureIsNonAuthoritativeAndDoesNotInferApplications() {
    let catalog = MailCatalog(applicationLocator: MailApplicationLocatorStub(error: StubError.failed))

    let result = catalog.scanResult()

    #expect(!result.isAuthoritative)
    #expect(result.applications.isEmpty)
  }

  @Test func reconcileAddsEnabledMailTargetsInScanOrderAfterExistingMailOrders() {
    let existingMail = mailTarget(
      bundleIdentifier: "com.example.existing",
      label: "Existing",
      enabled: false,
      order: 4,
      availability: .available
    )
    let webTarget = browserTarget(bundleIdentifier: "com.google.Chrome", order: 99)
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [browserApplication(), mailApplication("com.example.existing")],
      targets: [webTarget, existingMail]
    )
    let scan = MailScanResult(
      applications: [
        discoveredMail("com.example.first", name: "First"),
        discoveredMail("com.example.second", name: "Second"),
      ],
      isAuthoritative: true
    )

    let result = MailCatalog.reconcile(scan, with: config)

    let mailTargets = result.targets.filter { $0.routeKind == .mail }
    #expect(mailTargets.map(\.id) == [
      "mailto|com.example.existing",
      "mailto|com.example.first",
      "mailto|com.example.second",
    ])
    #expect(mailTargets.map(\.sortOrder) == [4, 5, 6])
    #expect(mailTargets.suffix(2).allSatisfy { $0.isEnabled && $0.availability == .available })
    #expect(result.targets.first { $0.routeKind == .web } == webTarget)
  }

  @Test func reconcilePreservesExistingMailCustomizationWhileRefreshingAvailability() {
    let existing = mailApplication("com.example.client", available: false)
    let target = mailTarget(
      bundleIdentifier: existing.bundleIdentifier,
      label: "My Client",
      enabled: false,
      order: 7,
      availability: .unavailable
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [existing],
      targets: [target]
    )
    let discovered = discoveredMail(
      existing.bundleIdentifier,
      name: "Client Renamed",
      path: "/Applications/Client Renamed.app"
    )

    let result = MailCatalog.reconcile(
      MailScanResult(applications: [discovered], isAuthoritative: true),
      with: config
    )

    #expect(result.applications.first?.displayName == "Client Renamed")
    #expect(result.applications.first?.applicationURL == discovered.applicationURL)
    #expect(result.applications.first?.isAvailable(for: .mail) == true)
    #expect(result.targets == [
      mailTarget(
        bundleIdentifier: existing.bundleIdentifier,
        label: "My Client",
        enabled: false,
        order: 7,
        availability: .available
      )
    ])
  }

  @Test func reconcileMarksMissingMailStateUnavailableWithoutChangingBrowserState() {
    let browser = browserApplication()
    let combined = RoutedApplication(
      id: browser.id,
      displayName: browser.displayName,
      bundleIdentifier: browser.bundleIdentifier,
      capabilities: [
        .browser(family: .chromium, isAvailable: true),
        .mail(isAvailable: true),
      ],
      applicationURL: browser.applicationURL,
      browserExecutableURL: browser.browserExecutableURL
    )
    let web = browserTarget(bundleIdentifier: browser.bundleIdentifier, order: 2)
    let mail = mailTarget(
      bundleIdentifier: browser.bundleIdentifier,
      label: "Chrome Mail",
      enabled: false,
      order: 8,
      availability: .available
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [combined],
      targets: [web, mail]
    )

    let result = MailCatalog.reconcile(
      MailScanResult(applications: [], isAuthoritative: true),
      with: config
    )

    #expect(result.applications.first?.capabilities == [
      .browser(family: .chromium, isAvailable: true),
      .mail(isAvailable: false),
    ])
    #expect(result.targets.first { $0.routeKind == .web } == web)
    #expect(result.targets.first { $0.routeKind == .mail } == mailTarget(
      bundleIdentifier: browser.bundleIdentifier,
      label: "Chrome Mail",
      enabled: false,
      order: 8,
      availability: .unavailable
    ))
  }

  @Test func reconcileRestoresMissingMailApplicationCustomizationOnReinstall() {
    let original = mailApplication("com.example.client")
    let configured = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [original],
      targets: [
        mailTarget(
          bundleIdentifier: original.bundleIdentifier,
          label: "Client Alias",
          enabled: false,
          order: 11,
          availability: .available
        )
      ]
    )
    let missing = MailCatalog.reconcile(
      MailScanResult(applications: [], isAuthoritative: true),
      with: configured
    )

    let restored = MailCatalog.reconcile(
      MailScanResult(
        applications: [discoveredMail(original.bundleIdentifier, name: "Client Reinstalled")],
        isAuthoritative: true
      ),
      with: missing
    )

    #expect(restored.applications.first?.isAvailable(for: .mail) == true)
    #expect(restored.targets == [
      mailTarget(
        bundleIdentifier: original.bundleIdentifier,
        label: "Client Alias",
        enabled: false,
        order: 11,
        availability: .available
      )
    ])
  }

  @Test func reconcileMergesMailCapabilityIntoExistingBrowserApplication() {
    let existing = chromeOnlyConfig
    let discovered = DiscoveredMailApplication(
      bundleIdentifier: "com.google.Chrome",
      displayName: "Google Chrome",
      applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")
    )

    let result = MailCatalog.reconcile(
      MailScanResult(applications: [discovered], isAuthoritative: true),
      with: existing
    )

    #expect(result.applications.count == 1)
    #expect(result.applications[0].supports(.web))
    #expect(result.applications[0].supports(.mail))
    #expect(result.targets.filter { $0.routeKind == .mail }.map(\.id) == [
      "mailto|com.google.Chrome"
    ])
    #expect(result.targets.first { $0.routeKind == .mail }?.isEnabled == true)
  }

  @Test func runtimeFallbackReResolvesMailWithoutChangingPersistedCustomization() {
    let browser = browserApplication()
    let combined = RoutedApplication(
      id: browser.id,
      displayName: browser.displayName,
      bundleIdentifier: browser.bundleIdentifier,
      capabilities: [
        .browser(family: .chromium, isAvailable: true),
        .mail(isAvailable: true),
      ],
      applicationURL: URL(fileURLWithPath: "/Old/Google Chrome.app"),
      browserExecutableURL: browser.browserExecutableURL
    )
    let unavailable = mailApplication("com.example.missing", available: true)
    let web = browserTarget(bundleIdentifier: browser.bundleIdentifier, order: 3)
    let mail = mailTarget(
      bundleIdentifier: browser.bundleIdentifier,
      label: "Customized Chrome Mail",
      enabled: false,
      order: 8,
      availability: .available
    )
    let config = PickViaConfig(
      schemaVersion: PickViaConfig.currentSchemaVersion,
      applications: [combined, unavailable],
      targets: [web, mail]
    )
    let catalog = MailCatalog(applicationLocator: MailApplicationLocatorStub(
      urls: [],
      applications: [
        browser.bundleIdentifier: URL(fileURLWithPath: "/New/Google Chrome.app")
      ],
      error: StubError.failed
    ))

    let scan = catalog.scanResult()
    let fallback = catalog.runtimeSanitizedFallback(config)

    #expect(!scan.isAuthoritative)
    #expect(fallback.applications[0].applicationURL == URL(fileURLWithPath: "/New/Google Chrome.app"))
    #expect(fallback.applications[0].capabilities == [
      .browser(family: .chromium, isAvailable: true),
      .mail(isAvailable: true),
    ])
    #expect(fallback.applications[1].applicationURL == unavailable.applicationURL)
    #expect(fallback.applications[1].capabilities == [.mail(isAvailable: false)])
    #expect(fallback.targets == config.targets)
  }
}

private let chromeOnlyConfig = PickViaConfig(
  schemaVersion: PickViaConfig.currentSchemaVersion,
  applications: [browserApplication()],
  targets: [browserTarget(bundleIdentifier: "com.google.Chrome", order: 0)]
)

private func browserApplication() -> RoutedApplication {
  RoutedApplication(
    id: "com.google.Chrome",
    displayName: "Google Chrome",
    bundleIdentifier: "com.google.Chrome",
    capabilities: [.browser(family: .chromium, isAvailable: true)],
    applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
    browserExecutableURL: URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
  )
}

private func mailApplication(_ bundleIdentifier: String, available: Bool = true) -> RoutedApplication {
  RoutedApplication(
    id: bundleIdentifier,
    displayName: "Client",
    bundleIdentifier: bundleIdentifier,
    capabilities: [.mail(isAvailable: available)],
    applicationURL: URL(fileURLWithPath: "/Applications/Client.app")
  )
}

private func browserTarget(bundleIdentifier: String, order: Int) -> RouteTarget {
  RouteTarget(
    id: "\(bundleIdentifier)||normal",
    applicationID: bundleIdentifier,
    label: "Default browser",
    isEnabled: true,
    sortOrder: order,
    origin: .detected,
    availability: .available,
    capability: .browser(
      BrowserTargetOptions(
        profileIdentifier: nil,
        profileDisplayName: nil,
        profileIdentity: nil,
        profileLaunchPath: nil,
        mode: .normal,
        pendingDefaultMigration: false,
        validationError: nil
      )
    )
  )
}

private func mailTarget(
  bundleIdentifier: String,
  label: String,
  enabled: Bool,
  order: Int,
  availability: TargetAvailability
) -> RouteTarget {
  RouteTarget(
    id: RouteTarget.mailID(bundleIdentifier: bundleIdentifier),
    applicationID: bundleIdentifier,
    label: label,
    isEnabled: enabled,
    sortOrder: order,
    origin: .detected,
    availability: availability,
    capability: .mail
  )
}

private func discoveredMail(
  _ bundleIdentifier: String,
  name: String,
  path: String = "/Applications/Client.app"
) -> DiscoveredMailApplication {
  DiscoveredMailApplication(
    bundleIdentifier: bundleIdentifier,
    displayName: name,
    applicationURL: URL(fileURLWithPath: path)
  )
}

private enum StubError: Error {
  case failed
}

private final class MailApplicationLocatorStub:
  MailApplicationLocating,
  MailApplicationResolving,
  @unchecked Sendable
{
  let urls: [URL]
  let applications: [String: URL]
  let error: Error?
  private(set) var requestedURLs: [URL] = []

  init(urls: [URL] = [], applications: [String: URL] = [:], error: Error? = nil) {
    self.urls = urls
    self.applications = applications
    self.error = error
  }

  func applicationURLs(toOpen url: URL) throws -> [URL] {
    requestedURLs.append(url)
    if let error { throw error }
    return urls
  }

  func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
    applications[bundleIdentifier]
  }
}

private func withTemporaryApplications(
  _ body: (URL) throws -> Void
) throws {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "MailCatalogTests-\(UUID().uuidString)",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try body(root)
}

private func application(
  at url: URL,
  bundleIdentifier: String,
  displayName: String
) throws -> URL {
  let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
  let metadata: [String: Any] = [
    "CFBundleIdentifier": bundleIdentifier,
    "CFBundleDisplayName": displayName,
    "CFBundleName": displayName,
    "CFBundlePackageType": "APPL",
  ]
  let data = try PropertyListSerialization.data(
    fromPropertyList: metadata,
    format: .xml,
    options: 0
  )
  try data.write(to: contents.appending(path: "Info.plist"))
  return url
}
