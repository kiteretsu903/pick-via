import Foundation
import PickViaCore
import XCTest

@testable import PickVia

final class BrowserSettingsViewTests: XCTestCase {
  func testBrowserSettingsHelpersExcludeEnabledMailTargetForDualCapabilityApplication() {
    let application = RoutedApplication(
      id: "com.google.Chrome",
      displayName: "Google Chrome",
      bundleIdentifier: "com.google.Chrome",
      capabilities: [
        .browser(family: .chromium, isAvailable: true),
        .mail(isAvailable: true),
      ],
      applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")
    )
    let webTarget = BrowserTarget(
      id: "com.google.Chrome|Profile 1|normal",
      browserID: application.id,
      label: "Work",
      profileIdentifier: "Profile 1",
      profileDisplayName: "Work",
      profileIdentity: "Profile 1",
      mode: .normal,
      isEnabled: true,
      sortOrder: 0,
      origin: .detected,
      availability: .available
    )
    let mailTarget = RouteTarget(
      id: RouteTarget.mailID(bundleIdentifier: application.bundleIdentifier),
      applicationID: application.id,
      label: "Google Chrome Mail",
      isEnabled: true,
      sortOrder: 1,
      origin: .detected,
      availability: .available,
      capability: .mail
    )

    XCTAssertEqual(
      browserSettingsTargets(
        browserID: application.id,
        targets: [mailTarget, webTarget]
      ).map(\.id),
      [webTarget.id]
    )
    XCTAssertEqual(
      availableProfileChoices(
        browserID: application.id,
        targets: [mailTarget, webTarget]
      ),
      [BrowserProfileChoice(identifier: "Profile 1", displayName: "Work")]
    )
  }

  func testAddTargetCapabilitiesCoverAllCombinationsWithoutFamilyPolicy() throws {
    let opera = settingsBrowser(
      bundleIdentifier: "com.operasoftware.Opera",
      persistedFamily: .firefox
    )
    let duckDuckGo = settingsBrowser(
      bundleIdentifier: DuckDuckGoBuildCompatibilityChecker.bundleIdentifier,
      persistedFamily: .safari
    )
    let chrome = settingsBrowser(
      bundleIdentifier: "com.google.Chrome",
      persistedFamily: .safari
    )
    let shortcutDescriptor = BrowserDescriptor(
      bundleIdentifier: "com.example.settings-shortcut",
      family: .safari,
      displayName: "Shortcut Browser",
      profileStrategy: .safariShortcut,
      launchStrategy: .workspace,
      privateStrategy: .safariShortcut
    )
    let shortcut = BrowserApplication(
      id: shortcutDescriptor.bundleIdentifier,
      family: shortcutDescriptor.family,
      displayName: shortcutDescriptor.displayName,
      bundleIdentifier: shortcutDescriptor.bundleIdentifier,
      applicationURL: URL(fileURLWithPath: "/Applications/Shortcut Browser.app"),
      executableURL: nil,
      isAvailable: true
    )
    let normalOnly = [settingsTarget(browser: opera, mode: .normal)]
    let normalAndPrivate = [
      settingsTarget(browser: duckDuckGo, mode: .normal),
      settingsTarget(browser: duckDuckGo, mode: .private),
    ]
    let profile = settingsTarget(
      browser: chrome,
      profileIdentifier: "Profile 1",
      mode: .normal
    )
    let normalAndProfiles = [
      settingsTarget(browser: shortcut, mode: .normal),
      settingsTarget(browser: shortcut, profileIdentifier: "Work Helper", mode: .normal),
    ]
    let allThree =
      [settingsTarget(browser: chrome, mode: .normal), profile] + [
        settingsTarget(browser: chrome, mode: .private),
        settingsTarget(browser: chrome, profileIdentifier: "Profile 1", mode: .private),
      ]

    XCTAssertEqual(
      browserTargetCapabilities(for: opera, targets: normalOnly),
      BrowserTargetCapabilities(supportsProfiles: false, supportsPrivateMode: false)
    )
    XCTAssertEqual(
      browserTargetCapabilities(for: duckDuckGo, targets: normalAndPrivate),
      BrowserTargetCapabilities(supportsProfiles: false, supportsPrivateMode: true)
    )
    XCTAssertEqual(
      browserTargetCapabilities(
        for: duckDuckGo,
        targets: [
          settingsTarget(browser: duckDuckGo, mode: .normal),
          settingsTarget(browser: duckDuckGo, mode: .private, availability: .unavailable),
        ]
      ),
      BrowserTargetCapabilities(supportsProfiles: false, supportsPrivateMode: false)
    )
    XCTAssertEqual(
      browserTargetCapabilities(
        for: shortcut,
        descriptor: shortcutDescriptor,
        targets: normalAndProfiles
      ),
      BrowserTargetCapabilities(supportsProfiles: true, supportsPrivateMode: false)
    )
    XCTAssertEqual(
      browserTargetCapabilities(for: chrome, targets: allThree),
      BrowserTargetCapabilities(supportsProfiles: true, supportsPrivateMode: true)
    )
    XCTAssertEqual(
      browserTargetCapabilities(
        for: chrome,
        targets: [settingsTarget(browser: chrome, mode: .normal), profile]
      ),
      BrowserTargetCapabilities(supportsProfiles: true, supportsPrivateMode: true)
    )
    XCTAssertEqual(
      availableBrowsersForManualTargets([opera, duckDuckGo, chrome]).map(\.id),
      [opera.id, duckDuckGo.id, chrome.id]
    )
  }

  func testAddTargetViewHasNoSafariFamilyPolicyBranches() throws {
    let source = try projectSource("Sources/PickVia/Views/BrowserSettingsView.swift")
    let modelSource = try projectSource("Sources/PickVia/App/AppModel.swift")

    XCTAssertFalse(source.contains("family == .safari"))
    XCTAssertFalse(source.contains("family != .safari"))
    XCTAssertTrue(source.contains("browserTargetCapabilities"))
    XCTAssertTrue(source.contains("BrowserPrivateCapabilityResolver.isAvailable"))
    XCTAssertTrue(modelSource.contains("BrowserPrivateCapabilityResolver.isAvailable"))
    XCTAssertFalse(modelSource.contains("private func hasAvailableDetectedPrivateTarget"))
  }

  func testGeneralSettingsContainsSegmentedChooserSizePicker() throws {
    let source = try projectSource("Sources/PickVia/Views/GeneralSettingsView.swift")

    XCTAssertTrue(source.contains("Picker(\"Chooser size\""))
    XCTAssertTrue(source.contains("ChooserDensity.allCases"))
    XCTAssertTrue(source.contains(".pickerStyle(.segmented)"))
  }

  func testFixedActionStripContainsStableLabeledActionsAndProfileAccessFlow() throws {
    let source = try projectSource("Sources/PickVia/Views/BrowserSettingsView.swift")
    let strip = try fixedActionStrip(in: source)

    XCTAssertTrue(strip.contains("VStack(spacing: 0)"))
    XCTAssertTrue(strip.contains("Label(\"Add Target\", systemImage: \"plus\")"))
    XCTAssertTrue(strip.contains("Label(\"Profile Access\", systemImage: \"folder.badge.key\")"))
    XCTAssertTrue(strip.contains("Label(\"Rescan\", systemImage: \"arrow.clockwise\")"))
    XCTAssertTrue(strip.contains(".labelStyle(.titleAndIcon)"))
    XCTAssertTrue(strip.contains("model.openProfileAccessManager()"))
    XCTAssertTrue(strip.contains("profileAccessPresenter.request(model: model)"))
  }

  func testBrowserSettingsRejectsAnyNativeToolbarPlacement() throws {
    let source = try projectSource("Sources/PickVia/Views/BrowserSettingsView.swift")

    XCTAssertFalse(source.contains(".toolbar"))
    XCTAssertFalse(source.contains("ToolbarItem"))
  }

  func testChooserUsesAdaptiveTargetScrollingAndDensityWidth() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserView.swift")

    XCTAssertTrue(source.contains("ViewThatFits(in: .vertical)"))
    XCTAssertTrue(source.contains("ScrollViewReader"))
    XCTAssertTrue(source.contains("scrollTo(selectedTargetID"))
    XCTAssertTrue(source.contains(".frame(width: density.metrics.contentWidth)"))
    XCTAssertTrue(source.contains(".lineLimit(1)"))
  }

  func testChooserRowsAreSingleLineAndDoNotRenderDetailText() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserView.swift")
    XCTAssertFalse(source.contains("detail(for:"))
    XCTAssertTrue(source.contains("ChooserTargetRow("))

    let rowSource = try projectSource("Sources/PickVia/Chooser/ChooserTargetRow.swift")
    XCTAssertTrue(rowSource.contains("Text(label)"))
    XCTAssertTrue(rowSource.contains(".lineLimit(1)"))
    XCTAssertTrue(rowSource.contains(".truncationMode(.tail)"))
    XCTAssertFalse(rowSource.contains("VStack"))
  }

  func testChooserSelectionUsesTintAndInsetBorderWithoutShadow() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserTargetRow.swift")
    let fillStart = try XCTUnwrap(source.range(of: "private var selectionFill: Color"))
    let fillEnd = try XCTUnwrap(
      source.range(
        of: "private func applicationIcon", range: fillStart.upperBound..<source.endIndex)
    )
    let fill = String(source[fillStart.lowerBound..<fillEnd.lowerBound])
    let selected = try XCTUnwrap(
      fill.range(of: "if isSelected { return Color.accentColor.opacity(0.16) }")
    )
    let hover = try XCTUnwrap(
      fill.range(of: "if isHovering { return Color.accentColor.opacity(0.07) }")
    )

    XCTAssertLessThan(selected.lowerBound, hover.lowerBound)
    XCTAssertTrue(source.contains("isSelected ? Color.accentColor.opacity(0.55) : .clear"))
    XCTAssertTrue(source.contains(".strokeBorder"))
    XCTAssertTrue(source.contains(".onHover { isHovering = $0 }"))
    XCTAssertFalse(source.contains(".shadow"))
  }

  func testChooserRowsDisableNativeFocusEffect() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserTargetRow.swift")

    XCTAssertTrue(source.contains(".buttonStyle(.plain)\n    .focusEffectDisabled()"))
  }

  func testChooserUsesStandardWindowCornerRadius() throws {
    let source = try projectSource("Sources/PickVia/Chooser/ChooserView.swift")

    XCTAssertTrue(
      source.contains(
        ".clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))"
      )
    )
  }

  private func fixedActionStrip(in source: String) throws -> String {
    let body = try XCTUnwrap(source.range(of: "public var body: some View {"))
    let dividerAndList = try XCTUnwrap(
      source.range(
        of: "\n      Divider()\n\n      List {",
        range: body.upperBound..<source.endIndex
      )
    )
    return String(source[body.upperBound..<dividerAndList.lowerBound])
  }

  private func projectSource(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repositoryRoot.appending(path: relativePath),
      encoding: .utf8
    )
  }
}

private func settingsBrowser(
  bundleIdentifier: String,
  persistedFamily: BrowserFamily
) -> BrowserApplication {
  let descriptor = BrowserDescriptor.descriptor(forBundleIdentifier: bundleIdentifier)!
  return BrowserApplication(
    id: bundleIdentifier,
    family: persistedFamily,
    displayName: descriptor.displayName,
    bundleIdentifier: bundleIdentifier,
    applicationURL: URL(fileURLWithPath: "/Applications/\(descriptor.displayName).app"),
    executableURL: nil,
    isAvailable: true
  )
}

private func settingsTarget(
  browser: BrowserApplication,
  profileIdentifier: String? = nil,
  mode: BrowserMode,
  availability: BrowserTargetAvailability = .available
) -> BrowserTarget {
  BrowserTarget(
    id: BrowserCatalog.targetID(
      bundleIdentifier: browser.bundleIdentifier,
      profileIdentifier: profileIdentifier,
      mode: mode
    ),
    browserID: browser.id,
    label: profileIdentifier ?? browser.displayName,
    profileIdentifier: profileIdentifier,
    profileDisplayName: profileIdentifier,
    profileIdentity: profileIdentifier,
    mode: mode,
    isEnabled: true,
    sortOrder: 0,
    origin: .detected,
    availability: availability
  )
}
