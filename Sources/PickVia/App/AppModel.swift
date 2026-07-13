import Foundation
import Observation
import PickViaCore

@MainActor
@Observable
public final class AppModel {
  public private(set) var config: PickViaConfig = .initial
  public private(set) var defaultStatus: DefaultBrowserStatus = .unknown
  public private(set) var launchesAtLogin = false
  public private(set) var errorMessage: String?
  public private(set) var configurationRecovery: ConfigurationRecoveryState = .none

  public var showsURLInChooser: Bool {
    didSet {
      guard isLoaded else { return }
      preferences.set(showsURLInChooser, forKey: PreferenceKey.showsURLInChooser)
    }
  }

  public private(set) var onboardingStep: Int {
    didSet {
      guard isLoaded else { return }
      preferences.set(onboardingStep, forKey: PreferenceKey.onboardingStep)
    }
  }

  public var browsers: [BrowserApplication] { config.browsers }
  public var targets: [BrowserTarget] { config.targets }
  public var isOnboardingComplete: Bool {
    onboardingStep == Onboarding.completedStep && hasConfirmedDefaultStatus
  }

  public var canRequestDefaultBrowser: Bool {
    config.targets.contains { target in
      guard
        target.isEnabled,
        target.availability == .available,
        let browser = config.browsers.first(where: { $0.id == target.browserID })
      else { return false }
      return browser.isAvailable
    }
  }

  private let configStore: any ConfigStoring
  private let browserCatalog: any BrowserDiscovering
  private let preferences: any PreferencesStoring
  private let defaultBrowser: any DefaultBrowserServicing
  private let loginItem: any LoginItemServicing
  private let routing: any AppRouting
  private let targetSnapshot: MutableTargetSnapshot?
  private var isLoaded = false

  public init(
    configStore: any ConfigStoring,
    browserCatalog: any BrowserDiscovering,
    preferences: any PreferencesStoring,
    defaultBrowser: any DefaultBrowserServicing,
    loginItem: any LoginItemServicing,
    routing: any AppRouting,
    targetSnapshot: MutableTargetSnapshot? = nil
  ) {
    self.configStore = configStore
    self.browserCatalog = browserCatalog
    self.preferences = preferences
    self.defaultBrowser = defaultBrowser
    self.loginItem = loginItem
    self.routing = routing
    self.targetSnapshot = targetSnapshot
    showsURLInChooser = true
    onboardingStep = 1
  }

  public func load() throws {
    guard !isLoaded else { return }

    let loadOutcome = configStore.loadOutcome()
    let loadedConfig: PickViaConfig
    switch loadOutcome {
    case .missing(let loaded), .loaded(let loaded):
      loadedConfig = loaded
    case .recoveredCorruption(let recovered):
      loadedConfig = recovered
      configurationRecovery = .recoveredCorruption
      errorMessage =
        "PickVia recovered a corrupt configuration. Review Browser settings before continuing."
    case .failure:
      loadedConfig = .initial
      configurationRecovery = .loadFailed
      errorMessage =
        "PickVia could not read its configuration. The existing file was left unchanged."
    }
    config = loadedConfig
    targetSnapshot?.publish(config)

    if configurationRecovery != .loadFailed {
      let scan = browserCatalog.scanResult()
      if scan.isAuthoritative {
        let reconciled = browserCatalog.reconcile(discovered: scan.browsers, with: loadedConfig)
        config = reconciled
        targetSnapshot?.publish(config)
        do {
          try configStore.save(reconciled)
        } catch {
          errorMessage =
            "Browser discovery succeeded, but the refreshed configuration could not be saved."
        }
        if !scan.warnings.isEmpty, configurationRecovery == .none, errorMessage == nil {
          errorMessage =
            "Some browser profile metadata could not be read. Existing targets were preserved."
        }
      } else if configurationRecovery == .none {
        errorMessage = "Browser discovery could not be completed. Existing targets were preserved."
      }
    }
    showsURLInChooser = preferences.bool(forKey: PreferenceKey.showsURLInChooser) ?? true
    launchesAtLogin = loginItem.isEnabled
    defaultStatus = defaultBrowser.status()
    let persistedStep =
      preferences.integer(forKey: PreferenceKey.onboardingStep) ?? Onboarding.firstStep
    onboardingStep = normalizedOnboardingStep(persistedStep)
    if onboardingStep != persistedStep {
      preferences.set(onboardingStep, forKey: PreferenceKey.onboardingStep)
    }
    isLoaded = true
  }

  public func advanceOnboarding() {
    switch onboardingStep {
    case Onboarding.firstStep:
      onboardingStep = 2
    case 2 where canRequestDefaultBrowser:
      onboardingStep = Onboarding.defaultBrowserStep
    default:
      break
    }
  }

  public func rescan() throws {
    let scan = browserCatalog.scanResult()
    guard scan.isAuthoritative else {
      errorMessage = "Browser discovery could not be completed. Existing targets were preserved."
      return
    }
    let reconciled = browserCatalog.reconcile(discovered: scan.browsers, with: config)
    try configStore.save(reconciled)
    config = reconciled
    targetSnapshot?.publish(config)
    routing.refreshCurrent()
    errorMessage =
      scan.warnings.isEmpty
      ? nil
      : "Some browser profile metadata could not be read. Existing targets were preserved."
  }

  public func refreshDefaultStatus() {
    defaultStatus = defaultBrowser.status()
  }

  public func accept(url: URL) {
    do {
      let validated = try URLValidator.validate(url)
      routing.accept(validated)
      errorMessage = nil
    } catch {
      errorMessage = "Only valid HTTP and HTTPS URLs can be opened."
    }
  }

  public func previewChooser() {
    routing.preview(URL(string: "https://pickvia.invalid/chooser-preview")!)
  }

  public func requestDefaultBrowser() async {
    guard canRequestDefaultBrowser else { return }

    // Status is authoritative; refresh it even when the consent API throws.
    _ = try? await defaultBrowser.requestDefault(for: ["http", "https"])
    defaultStatus = defaultBrowser.status()

    if hasConfirmedDefaultStatus {
      onboardingStep = Onboarding.completedStep
      errorMessage = nil
    } else {
      if onboardingStep >= Onboarding.completedStep {
        onboardingStep = Onboarding.defaultBrowserStep
      }
      errorMessage =
        "PickVia was not made the default browser for HTTP and HTTPS. You can try again."
    }
  }

  public func setLaunchAtLogin(_ enabled: Bool) {
    let previous = launchesAtLogin
    launchesAtLogin = enabled
    errorMessage = nil

    do {
      try loginItem.setEnabled(enabled)
    } catch {
      launchesAtLogin = previous
      errorMessage = "The launch-at-login setting could not be changed."
    }
  }

  public func renameTarget(id: BrowserTarget.ID, label: String) throws {
    let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { throw TargetEditingError.blankLabel }
    try updateTarget(id: id) { target in
      copy(target, label: label)
    }
  }

  public func setTargetEnabled(id: BrowserTarget.ID, isEnabled: Bool) throws {
    try updateTarget(id: id) { target in
      copy(target, isEnabled: isEnabled)
    }
  }

  public func setTargetMode(id: BrowserTarget.ID, mode: BrowserMode) throws {
    try updateTarget(id: id) { [config] target in
      guard target.origin == .manual || target.mode == mode else {
        throw TargetEditingError.detectedTargetIdentityIsImmutable
      }
      guard let browser = config.browsers.first(where: { $0.id == target.browserID }) else {
        throw TargetEditingError.browserNotFound
      }
      guard browser.family != .safari || mode == .normal else {
        throw TargetEditingError.safariPrivateModeUnsupported
      }
      return copy(target, mode: mode)
    }
  }

  public func setTargetProfile(
    id: BrowserTarget.ID,
    profileIdentifier: String?
  ) throws {
    try updateTarget(id: id) { [config] target in
      guard target.origin == .manual || target.profileIdentifier == profileIdentifier else {
        throw TargetEditingError.detectedTargetIdentityIsImmutable
      }
      guard let browser = supportedAvailableBrowser(id: target.browserID, in: config) else {
        throw TargetEditingError.browserUnavailableOrUnsupported
      }
      if browser.family == .safari {
        guard profileIdentifier == nil else { throw TargetEditingError.invalidProfileIdentity }
        return copy(
          target,
          profileIdentifier: nil,
          profileDisplayName: nil,
          profileIdentity: nil
        )
      }
      if profileIdentifier == nil {
        return copy(
          target,
          profileIdentifier: nil,
          profileDisplayName: nil,
          profileIdentity: nil
        )
      }
      guard
        let profileIdentifier,
        !profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let candidate = detectedProfileTarget(
          browserID: browser.id,
          profileIdentifier: profileIdentifier,
          in: config
        )
      else { throw TargetEditingError.invalidProfileIdentity }
      return copy(
        target,
        profileIdentifier: candidate.profileIdentifier,
        profileDisplayName: candidate.profileDisplayName,
        profileIdentity: candidate.profileIdentity
      )
    }
  }

  public func moveTargets(fromOffsets offsets: IndexSet, toOffset destination: Int) throws {
    var ordered = config.targets.sorted {
      if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
      return $0.id < $1.id
    }
    guard
      !offsets.isEmpty,
      offsets.allSatisfy({ ordered.indices.contains($0) }),
      (0...ordered.count).contains(destination)
    else { throw TargetEditingError.invalidMove }

    let moved = offsets.map { ordered[$0] }
    for index in offsets.reversed() {
      ordered.remove(at: index)
    }
    let insertionIndex = destination - offsets.filter { $0 < destination }.count
    ordered.insert(contentsOf: moved, at: insertionIndex)
    ordered = ordered.enumerated().map { copy($0.element, sortOrder: $0.offset) }
    try persist(targets: ordered)
  }

  @discardableResult
  public func addManualTarget(
    browserID: BrowserApplication.ID,
    profileIdentifier: String?,
    label: String,
    mode: BrowserMode
  ) throws -> BrowserTarget.ID {
    let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !label.isEmpty else { throw TargetEditingError.blankLabel }
    guard let browser = supportedAvailableBrowser(id: browserID, in: config) else {
      throw TargetEditingError.browserUnavailableOrUnsupported
    }
    guard browser.family != .safari || mode == .normal else {
      throw TargetEditingError.safariPrivateModeUnsupported
    }

    let profileDisplayName: String?
    if browser.family == .safari {
      guard profileIdentifier == nil else { throw TargetEditingError.invalidProfileIdentity }
      profileDisplayName = nil
    } else if profileIdentifier == nil {
      profileDisplayName = nil
    } else {
      guard
        let profileIdentifier,
        !profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let profileTarget = detectedProfileTarget(
          browserID: browserID,
          profileIdentifier: profileIdentifier,
          in: config
        )
      else { throw TargetEditingError.invalidProfileIdentity }
      profileDisplayName = profileTarget.profileDisplayName
    }

    let id = UUID().uuidString
    let target = BrowserTarget(
      id: id,
      browserID: browserID,
      label: label,
      profileIdentifier: profileIdentifier,
      profileDisplayName: profileDisplayName,
      profileIdentity: profileIdentifier.flatMap { identity in
        detectedProfileTarget(
          browserID: browserID,
          profileIdentifier: identity,
          in: config
        )?.profileIdentity
      },
      mode: mode,
      isEnabled: true,
      sortOrder: (config.targets.map(\.sortOrder).max() ?? -1) + 1,
      origin: .manual,
      availability: .available
    )
    try persist(targets: config.targets + [target])
    return id
  }

  public func removeManualTarget(id: BrowserTarget.ID) throws {
    guard let target = config.targets.first(where: { $0.id == id }) else {
      throw TargetEditingError.targetNotFound
    }
    guard target.origin == .manual else { throw TargetEditingError.detectedTargetCannotBeRemoved }
    try persist(targets: config.targets.filter { $0.id != id })
  }

  private func updateTarget(
    id: BrowserTarget.ID,
    transform: (BrowserTarget) throws -> BrowserTarget
  ) throws {
    guard let index = config.targets.firstIndex(where: { $0.id == id }) else {
      throw TargetEditingError.targetNotFound
    }
    var targets = config.targets
    targets[index] = try transform(targets[index])
    try persist(targets: targets)
  }

  private func persist(targets: [BrowserTarget]) throws {
    let updated = PickViaConfig(
      schemaVersion: config.schemaVersion,
      browsers: config.browsers,
      targets: targets
    )
    try configStore.save(updated)
    config = updated
    targetSnapshot?.publish(config)
    routing.refreshCurrent()
    errorMessage = nil
  }

  private var hasConfirmedDefaultStatus: Bool {
    defaultStatus.http == .isDefault && defaultStatus.https == .isDefault
  }

  private func normalizedOnboardingStep(_ persistedStep: Int) -> Int {
    let bounded = min(
      max(persistedStep, Onboarding.firstStep),
      Onboarding.completedStep
    )
    if bounded == Onboarding.completedStep && !hasConfirmedDefaultStatus {
      return Onboarding.defaultBrowserStep
    }
    return bounded
  }
}

public enum TargetEditingError: Error, Equatable {
  case targetNotFound
  case browserNotFound
  case blankLabel
  case safariPrivateModeUnsupported
  case browserUnavailableOrUnsupported
  case invalidProfileIdentity
  case detectedTargetIdentityIsImmutable
  case detectedTargetCannotBeRemoved
  case invalidMove
}

public enum ConfigurationRecoveryState: Equatable {
  case none
  case recoveredCorruption
  case loadFailed
}

private func copy(
  _ target: BrowserTarget,
  label: String? = nil,
  mode: BrowserMode? = nil,
  isEnabled: Bool? = nil,
  sortOrder: Int? = nil
) -> BrowserTarget {
  BrowserTarget(
    id: target.id,
    browserID: target.browserID,
    label: label ?? target.label,
    profileIdentifier: target.profileIdentifier,
    profileDisplayName: target.profileDisplayName,
    profileIdentity: target.profileIdentity,
    mode: mode ?? target.mode,
    isEnabled: isEnabled ?? target.isEnabled,
    sortOrder: sortOrder ?? target.sortOrder,
    origin: target.origin,
    availability: target.availability,
    validationError: target.validationError
  )
}

private func copy(
  _ target: BrowserTarget,
  profileIdentifier: String?,
  profileDisplayName: String?,
  profileIdentity: String?
) -> BrowserTarget {
  BrowserTarget(
    id: target.id,
    browserID: target.browserID,
    label: target.label,
    profileIdentifier: profileIdentifier,
    profileDisplayName: profileDisplayName,
    profileIdentity: profileIdentity,
    mode: target.mode,
    isEnabled: target.isEnabled,
    sortOrder: target.sortOrder,
    origin: target.origin,
    availability: target.availability,
    validationError: target.validationError
  )
}

private func supportedAvailableBrowser(
  id: BrowserApplication.ID,
  in config: PickViaConfig
) -> BrowserApplication? {
  guard let browser = config.browsers.first(where: { $0.id == id && $0.isAvailable }) else {
    return nil
  }
  return BrowserDescriptor.supported.contains {
    $0.bundleIdentifier == browser.bundleIdentifier && $0.family == browser.family
  } ? browser : nil
}

private func detectedProfileTarget(
  browserID: BrowserApplication.ID,
  profileIdentifier: String,
  in config: PickViaConfig
) -> BrowserTarget? {
  config.targets.first {
    $0.browserID == browserID
      && ($0.profileIdentifier == profileIdentifier
        || ($0.profileIdentity ?? $0.profileIdentifier) == profileIdentifier)
      && $0.origin == .detected
      && $0.availability == .available
  }
}

enum PreferenceKey {
  static let showsURLInChooser = "showsURLInChooser"
  static let onboardingStep = "onboardingStep"
}

private enum Onboarding {
  static let firstStep = 1
  static let defaultBrowserStep = 3
  static let completedStep = 4
}
