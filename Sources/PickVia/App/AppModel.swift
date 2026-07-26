import Foundation
import Observation
import PickViaCore

@MainActor
@Observable
public final class AppModel {
  public private(set) var config: PickViaConfig = .initial
  public private(set) var defaultStatus: DefaultHandlerStatus = .unknown
  public private(set) var launchesAtLogin = false
  public private(set) var errorMessage: String?
  public private(set) var mailErrorMessage: String?
  public private(set) var configurationRecovery: ConfigurationRecoveryState = .none
  public private(set) var profileAccessRows: [BrowserProfileAccessRow] = []
  public private(set) var profileAccessPresentation: ProfileAccessPresentationState = .idle
  public private(set) var isProfileAccessSurfaceActive = false

  public var configurationRecoveryMessage: String? {
    switch configurationRecovery {
    case .none:
      nil
    case .recoveredCorruption:
      "PickVia recovered a corrupt configuration. Review Browser settings before continuing."
    case .loadFailed:
      "PickVia could not read its configuration. The existing file was left unchanged."
    }
  }

  public var showsURLInChooser: Bool {
    didSet {
      guard isLoaded else { return }
      preferences.set(showsURLInChooser, forKey: PreferenceKey.showsURLInChooser)
    }
  }

  public var chooserDensity: ChooserDensity {
    didSet {
      guard isLoaded else { return }
      preferences.set(chooserDensity.rawValue, forKey: PreferenceKey.chooserDensity)
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
  public var mailApplications: [RoutedApplication] {
    config.applications.filter { $0.supports(.mail) }
  }
  public var mailTargets: [RouteTarget] {
    config.targets.filter { $0.routeKind == .mail }
  }
  public var browserSettingsIssueSummary: BrowserSettingsIssueSummary {
    let overrides = targetedProfileAccessOverlays.reduce(
      into: [String: ProfileMetadataStatus]()
    ) { result, entry in
      result[entry.key] = entry.value.browser?.metadataStatus ?? .accessRevoked
    }
    let targetedDiscoveries = targetedProfileAccessOverlays.reduce(
      into: [String: DiscoveredBrowser]()
    ) { result, entry in
      if let browser = entry.value.browser {
        result[entry.key] = browser
      }
    }
    return makeBrowserSettingsIssueSummary(
      authoritativeScan: latestAuthoritativeBrowserScan,
      metadataOverrides: overrides,
      targetedDiscoveries: targetedDiscoveries,
      config: config
    )
  }

  public var isOnboardingComplete: Bool {
    onboardingStep == Onboarding.completedStep && hasConfirmedDefaultStatus
  }

  public var canRequestDefaultBrowser: Bool {
    canContinueOnboardingReview
      && !hasUnresolvedAutomaticProfileAccess
      && canPresentOrdinaryAppSurface
  }

  public var canContinueOnboardingReview: Bool {
    config.targets.contains { target in
      guard
        target.routeKind == .web,
        target.isEnabled,
        target.availability == .available,
        let browser = config.browsers.first(where: { $0.id == target.applicationID })
      else { return false }
      return browser.isAvailable(for: .web)
    }
  }

  public var hasUnresolvedAutomaticProfileAccess: Bool {
    switch profileAccessPresentation {
    case .automaticPending:
      true
    case .presented:
      isAutomaticProfileAccessFlowPresented
    case .idle, .manualPending, .suppressedForProcess:
      false
    }
  }

  public var canFinishProfileAccess: Bool {
    profileAccessRows.contains { row in
      switch row.state {
      case .granted:
        true
      case .invalidFolder:
        row.hasStoredGrant
      case .accessNeeded, .accessRevoked, .metadataDamaged:
        false
      }
    }
  }

  public var shouldAutomaticallyPresentProfileAccess: Bool {
    profileAccessPresentation == .automaticPending
  }

  public var canPresentOrdinaryAppSurface: Bool {
    !isProfileAccessSurfaceActive
  }

  private let configStore: any ConfigStoring
  private let browserCatalog: any BrowserDiscovering
  private let mailCatalog: any MailDiscovering
  private let preferences: any PreferencesStoring
  private let defaultBrowser: any DefaultHandlerServicing
  private let loginItem: any LoginItemServicing
  private let routing: any AppRouting
  private let targetSnapshot: MutableTargetSnapshot?
  private let profileAccess: any ProfileAccessManaging
  private let profileRootValidator: BrowserProfileRootValidator
  private var isLoaded = false
  private var latestAuthoritativeBrowserScan: BrowserScanResult?
  private var targetedProfileAccessOverlays: [String: TargetedProfileAccessOverlay] = [:]
  private var isAutomaticProfileAccessFlowPresented = false
  private var deferredAcceptedURLs: [URL] = []

  public init(
    configStore: any ConfigStoring,
    browserCatalog: any BrowserDiscovering,
    mailCatalog: any MailDiscovering = MissingMailCatalog(),
    preferences: any PreferencesStoring,
    defaultBrowser: any DefaultHandlerServicing,
    loginItem: any LoginItemServicing,
    routing: any AppRouting,
    targetSnapshot: MutableTargetSnapshot? = nil,
    profileAccess: any ProfileAccessManaging = MissingProfileAccessManager(),
    profileRootValidator: BrowserProfileRootValidator = BrowserProfileRootValidator()
  ) {
    self.configStore = configStore
    self.browserCatalog = browserCatalog
    self.mailCatalog = mailCatalog
    self.preferences = preferences
    self.defaultBrowser = defaultBrowser
    self.loginItem = loginItem
    self.routing = routing
    self.targetSnapshot = targetSnapshot
    self.profileAccess = profileAccess
    self.profileRootValidator = profileRootValidator
    showsURLInChooser = true
    chooserDensity = .compact
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
    case .failure:
      loadedConfig = .initial
      configurationRecovery = .loadFailed
    }

    let browserFallback = BrowserCatalog.runtimeSanitizedFallback(loadedConfig)
    let runtimeFallback = mailCatalog.runtimeSanitizedFallback(browserFallback)

    if configurationRecovery != .loadFailed {
      var candidate = runtimeFallback
      var browserChanged = false
      var mailChanged = false

      let browserScan = browserCatalog.scanResult()
      if browserScan.isAuthoritative {
        recordAuthoritativeScan(browserScan)
        do {
          let reconciled = browserCatalog.reconcile(
            discovered: browserScan.browsers,
            with: candidate
          )
          let validated = try replacingRouteSlice(
            .web,
            in: candidate,
            with: reconciled
          ).validatedAndMigrated()
          browserChanged = validated != candidate
          candidate = validated
        } catch {
          errorMessage = "Browser discovery produced a configuration that could not be committed."
        }
        if !browserScan.warnings.isEmpty,
          configurationRecovery == .none,
          errorMessage == nil
        {
          errorMessage =
            "Some browser profile metadata could not be read. Existing targets were preserved."
        }
      } else if configurationRecovery == .none {
        errorMessage = "Browser discovery could not be completed. Existing targets were preserved."
      }
      updateAutomaticProfileAccessRows(from: browserScan)

      let mailScan = mailCatalog.scanResult()
      if mailScan.isAuthoritative {
        do {
          let reconciled = mailCatalog.reconcile(mailScan, with: candidate)
          let validated = try replacingRouteSlice(
            .mail,
            in: candidate,
            with: reconciled
          ).validatedAndMigrated()
          mailChanged = validated != candidate
          candidate = validated
        } catch {
          mailErrorMessage =
            "Mail application discovery produced a configuration that could not be committed."
        }
      } else {
        mailErrorMessage =
          "Mail application discovery could not be completed. Existing choices were preserved."
      }

      if browserChanged || mailChanged {
        do {
          try configStore.save(candidate)
          config = candidate
        } catch {
          config = runtimeFallback
          if browserChanged {
            errorMessage =
              "Browser discovery produced a configuration that could not be committed."
          }
          if mailChanged {
            mailErrorMessage =
              "Mail application discovery produced a configuration that could not be committed."
          }
        }
      } else {
        config = candidate
      }
      targetSnapshot?.publish(config)
    } else {
      config = .initial
    }
    showsURLInChooser = preferences.bool(forKey: PreferenceKey.showsURLInChooser) ?? true
    chooserDensity = .fromPersistedValue(
      preferences.integer(forKey: PreferenceKey.chooserDensity)
    )
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
    case 2 where canContinueOnboardingReview:
      onboardingStep = Onboarding.defaultBrowserStep
    default:
      break
    }
  }

  public func rescan() throws {
    let scan = browserCatalog.scanResult()
    guard scan.isAuthoritative else {
      errorMessage = "Browser discovery could not be completed. Existing targets were preserved."
      updateAutomaticProfileAccessRows(from: scan)
      return
    }
    recordAuthoritativeScan(scan)
    do {
      try commitAuthoritativeScan(scan, base: config, refreshRouting: true)
    } catch {
      errorMessage = "Browser discovery produced a configuration that could not be committed."
      updateAutomaticProfileAccessRows(from: scan)
      throw error
    }
    errorMessage =
      scan.warnings.isEmpty
      ? nil
      : "Some browser profile metadata could not be read. Existing targets were preserved."
    updateAutomaticProfileAccessRows(from: scan)
  }

  public func rescanMailApplications() throws {
    let scan = mailCatalog.scanResult()
    guard scan.isAuthoritative else {
      mailErrorMessage =
        "Mail application discovery could not be completed. Existing choices were preserved."
      return
    }

    do {
      let reconciled = mailCatalog.reconcile(scan, with: config)
      let updated = try replacingRouteSlice(
        .mail,
        in: config,
        with: reconciled
      ).validatedAndMigrated()
      try configStore.save(updated)
      config = updated
      targetSnapshot?.publish(updated)
      routing.refreshCurrent()
      mailErrorMessage = nil
    } catch {
      mailErrorMessage =
        "Mail application discovery produced a configuration that could not be committed."
      throw error
    }
  }

  public func openProfileAccessManager() {
    guard canPresentOrdinaryAppSurface else { return }
    guard profileAccessPresentation != .automaticPending,
      !isAutomaticProfileAccessFlowPresented
    else { return }
    profileAccessRows = manualProfileAccessRows(from: latestAuthoritativeBrowserScan)
    isAutomaticProfileAccessFlowPresented = false
    profileAccessPresentation = .manualPending
  }

  public func userRequestedRescan() throws {
    guard canPresentOrdinaryAppSurface else { return }
    isAutomaticProfileAccessFlowPresented = false
    profileAccessPresentation = .idle
    try rescan()
  }

  public func grantProfileAccess(for bundleIdentifier: String, root: URL) throws {
    guard
      let index = profileAccessRows.firstIndex(where: {
        $0.bundleIdentifier == bundleIdentifier
      }),
      let descriptor = BrowserDescriptor.descriptor(
        forBundleIdentifier: bundleIdentifier
      )
    else { throw ProfileAccessFlowError.browserNotFound }

    let validation = profileRootValidator.validate(root, for: descriptor)
    switch validation {
    case .invalid(let requiredMarker):
      profileAccessRows[index].state = .invalidFolder(requiredMarker: requiredMarker)
      return
    case .unreadable:
      profileAccessRows[index].state = .invalidFolder(
        requiredMarker: profileAccessRows[index].requiredMarker
      )
      return
    case .valid:
      break
    }

    let persistence: ProfileGrantPersistence
    do {
      persistence = try profileAccess.installGrant(
        root: root,
        for: bundleIdentifier
      )
    } catch {
      errorMessage = "The selected browser folder access could not be saved."
      throw error
    }

    let targeted = browserCatalog.scanResult(for: bundleIdentifier)
    targetedProfileAccessOverlays[bundleIdentifier] = TargetedProfileAccessOverlay(
      browser: targeted
    )
    profileAccessRows[index].state = targetedProfileAccessState(
      targeted,
      persistence: persistence
    )
    profileAccessRows[index].hasStoredGrant = true
    errorMessage = nil
  }

  public func removeProfileAccess(for bundleIdentifier: String) throws {
    try profileAccess.removeGrant(for: bundleIdentifier)
    targetedProfileAccessOverlays[bundleIdentifier] = nil
    let scan = browserCatalog.scanResult()
    guard scan.isAuthoritative else {
      rebuildProfileAccessRows(using: latestAuthoritativeBrowserScan)
      errorMessage = "Browser discovery could not be completed. Existing targets were preserved."
      throw ProfileAccessFlowError.scanNotAuthoritative
    }
    recordAuthoritativeScan(scan)
    do {
      try commitAuthoritativeScan(scan, base: config, refreshRouting: true)
    } catch {
      rebuildProfileAccessRows(using: scan)
      errorMessage = "Browser discovery produced a configuration that could not be committed."
      throw error
    }
    profileAccessRows = manualProfileAccessRows(from: scan)
    errorMessage =
      scan.warnings.isEmpty
      ? nil
      : "Some browser profile metadata could not be read. Existing targets were preserved."
  }

  public func finishProfileAccessAndRescan() throws {
    let scan = browserCatalog.scanResult()
    guard scan.isAuthoritative else {
      errorMessage = "Browser discovery could not be completed. Existing targets were preserved."
      profileAccessPresentation = .presented
      throw ProfileAccessFlowError.scanNotAuthoritative
    }
    recordAuthoritativeScan(scan)
    do {
      try commitAuthoritativeScan(scan, base: config, refreshRouting: true)
    } catch {
      rebuildProfileAccessRows(using: scan)
      errorMessage = "Browser discovery produced a configuration that could not be committed."
      profileAccessPresentation = .presented
      throw error
    }
    profileAccessRows = manualProfileAccessRows(from: scan)
    isAutomaticProfileAccessFlowPresented = false
    profileAccessPresentation = .idle
    errorMessage =
      scan.warnings.isEmpty
      ? nil
      : "Some browser profile metadata could not be read. Existing targets were preserved."
  }

  public func skipProfileAccess() {
    isAutomaticProfileAccessFlowPresented = false
    profileAccessPresentation = .suppressedForProcess
  }

  public func closeProfileAccess() {
    isAutomaticProfileAccessFlowPresented = false
    profileAccessPresentation = .suppressedForProcess
  }

  public func profileAccessDidPresent() {
    switch profileAccessPresentation {
    case .automaticPending:
      isAutomaticProfileAccessFlowPresented = true
      profileAccessPresentation = .presented
      isProfileAccessSurfaceActive = true
    case .manualPending:
      isAutomaticProfileAccessFlowPresented = false
      profileAccessPresentation = .presented
      isProfileAccessSurfaceActive = true
    case .idle, .presented, .suppressedForProcess:
      break
    }
  }

  public func profileAccessDidDismiss() {
    guard isProfileAccessSurfaceActive else { return }
    isProfileAccessSurfaceActive = false
    let urls = deferredAcceptedURLs
    deferredAcceptedURLs.removeAll(keepingCapacity: true)
    for url in urls {
      routing.accept(url)
    }
  }

  public func reportProfileAccessCommitFailure() {
    profileAccessPresentation = .presented
    errorMessage = "Browser discovery produced a configuration that could not be committed."
  }

  public func refreshDefaultStatus() {
    defaultStatus = defaultBrowser.status()
  }

  public func settingsDidClose() {
    routing.refreshCurrent()
    if configurationRecovery == .recoveredCorruption {
      configurationRecovery = .none
    }
  }

  public func accept(url: URL) {
    do {
      let validated = try URLValidator.validate(url)
      if isProfileAccessSurfaceActive {
        deferredAcceptedURLs.append(validated.url)
      } else {
        routing.accept(validated.url)
      }
      errorMessage = nil
    } catch {
      errorMessage = "Only valid HTTP, HTTPS, and mailto URLs can be opened."
    }
  }

  public func previewChooser() {
    guard canPresentOrdinaryAppSurface else { return }
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
      copy(target, label: label, pendingDefaultMigration: false)
    }
  }

  public func setTargetEnabled(id: BrowserTarget.ID, isEnabled: Bool) throws {
    try updateTarget(id: id) { target in
      copy(target, isEnabled: isEnabled, pendingDefaultMigration: false)
    }
  }

  public func setTargetMode(id: BrowserTarget.ID, mode: BrowserMode) throws {
    try updateTarget(id: id) { [config] target in
      guard target.routeKind == .web else {
        throw TargetEditingError.routeKindMismatch
      }
      guard target.origin == .manual || target.mode == mode else {
        throw TargetEditingError.detectedTargetIdentityIsImmutable
      }
      guard let browser = config.browsers.first(where: { $0.id == target.browserID }) else {
        throw TargetEditingError.browserNotFound
      }
      guard browser.family != .safari || mode == .normal else {
        throw TargetEditingError.safariPrivateModeUnsupported
      }
      return copy(target, mode: mode, pendingDefaultMigration: false)
    }
  }

  public func setTargetProfile(
    id: BrowserTarget.ID,
    profileIdentifier: String?
  ) throws {
    try updateTarget(id: id) { [config] target in
      guard target.routeKind == .web else {
        throw TargetEditingError.routeKindMismatch
      }
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
          profileIdentity: nil,
          profileLaunchPath: nil
        )
      }
      if profileIdentifier == nil {
        return copy(
          target,
          profileIdentifier: nil,
          profileDisplayName: nil,
          profileIdentity: nil,
          profileLaunchPath: nil
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
        profileIdentity: candidate.profileIdentity,
        profileLaunchPath: candidate.profileLaunchPath
      )
    }
  }

  public func setMailTargetEnabled(
    id: RouteTarget.ID,
    isEnabled: Bool
  ) throws {
    try updateTarget(id: id) { target in
      guard target.routeKind == .mail else {
        throw TargetEditingError.routeKindMismatch
      }
      return copy(target, isEnabled: isEnabled)
    }
  }

  public func moveMailTargets(
    fromOffsets offsets: IndexSet,
    toOffset destination: Int
  ) throws {
    var orderedMail = mailTargets.sorted(by: targetDisplayOrder)
    guard
      !offsets.isEmpty,
      offsets.allSatisfy({ orderedMail.indices.contains($0) }),
      (0...orderedMail.count).contains(destination)
    else { throw TargetEditingError.invalidMove }

    let moved = offsets.map { orderedMail[$0] }
    for index in offsets.reversed() {
      orderedMail.remove(at: index)
    }
    let insertionIndex = destination - offsets.filter { $0 < destination }.count
    orderedMail.insert(contentsOf: moved, at: insertionIndex)
    orderedMail = orderedMail.enumerated().map { index, target in
      copy(target, sortOrder: index)
    }

    let updatedTargets =
      config.targets.filter { $0.routeKind == .web }
      + orderedMail
    try persist(targets: updatedTargets)
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
    let movedIDs = Set(moved.map(\.id))
    let originalIndexByID = Dictionary(
      uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) }
    )
    for index in offsets.reversed() {
      ordered.remove(at: index)
    }
    let insertionIndex = destination - offsets.filter { $0 < destination }.count
    ordered.insert(contentsOf: moved, at: insertionIndex)
    ordered = ordered.enumerated().map { index, target in
      copy(
        target,
        sortOrder: index,
        pendingDefaultMigration:
          originalIndexByID[target.id] == index && !movedIDs.contains(target.id)
          ? target.pendingDefaultMigration : false
      )
    }
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

    let selectedProfile: BrowserTarget?
    if browser.family == .safari {
      guard profileIdentifier == nil else { throw TargetEditingError.invalidProfileIdentity }
      selectedProfile = nil
    } else if profileIdentifier == nil {
      selectedProfile = nil
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
      selectedProfile = profileTarget
    }

    let id = UUID().uuidString
    let target = BrowserTarget(
      id: id,
      browserID: browserID,
      label: label,
      profileIdentifier: selectedProfile?.profileIdentifier,
      profileDisplayName: selectedProfile?.profileDisplayName,
      profileIdentity: selectedProfile?.profileIdentity,
      profileLaunchPath: selectedProfile?.profileLaunchPath,
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
      applications: config.applications,
      targets: targets
    )
    let validated = try updated.validatedAndMigrated()
    try configStore.save(validated)
    config = validated
    targetSnapshot?.publish(validated)
    errorMessage = nil
    mailErrorMessage = nil
  }

  private func commitAuthoritativeScan(
    _ scan: BrowserScanResult,
    base: PickViaConfig,
    refreshRouting: Bool
  ) throws {
    let reconciled = browserCatalog.reconcile(discovered: scan.browsers, with: base)
    let validated = try replacingRouteSlice(
      .web,
      in: base,
      with: reconciled
    ).validatedAndMigrated()
    try configStore.save(validated)
    config = validated
    targetSnapshot?.publish(validated)
    if refreshRouting {
      routing.refreshCurrent()
    }
  }

  private func targetedProfileAccessState(
    _ browser: DiscoveredBrowser?,
    persistence: ProfileGrantPersistence
  ) -> BrowserProfileAccessRowState {
    guard let browser else { return .accessRevoked }
    return switch browser.metadataStatus {
    case .loaded:
      .granted(profileCount: browser.profiles.count, persistence: persistence)
    case .accessRevoked:
      .accessRevoked
    case .metadataDamaged:
      .metadataDamaged
    case .notApplicable, .metadataAbsent, .accessRequired:
      .accessNeeded
    }
  }

  private func recordAuthoritativeScan(_ scan: BrowserScanResult) {
    latestAuthoritativeBrowserScan = scan
    targetedProfileAccessOverlays.removeAll()
  }

  private func rebuildProfileAccessRows(using scan: BrowserScanResult?) {
    profileAccessRows = manualProfileAccessRows(from: scan)
  }

  private func updateAutomaticProfileAccessRows(from scan: BrowserScanResult) {
    isAutomaticProfileAccessFlowPresented = false
    let wasSuppressed = profileAccessPresentation == .suppressedForProcess
    let issueByBundleIdentifier = Dictionary(
      uniqueKeysWithValues: scan.profileAccessIssues.compactMap { issue in
        switch issue {
        case .accessRequired(let bundleIdentifier):
          (bundleIdentifier, BrowserProfileAccessRowState.accessNeeded)
        case .accessRevoked(let bundleIdentifier):
          (bundleIdentifier, BrowserProfileAccessRowState.accessRevoked)
        case .metadataDamaged:
          nil
        }
      }
    )
    profileAccessRows = scan.browsers.compactMap { browser in
      guard let state = issueByBundleIdentifier[browser.application.bundleIdentifier] else {
        return nil
      }
      return profileAccessRow(for: browser, state: state)
    }
    if wasSuppressed {
      profileAccessPresentation = .suppressedForProcess
    } else {
      profileAccessPresentation = profileAccessRows.isEmpty ? .idle : .automaticPending
    }
  }

  private func manualProfileAccessRows(from scan: BrowserScanResult?) -> [BrowserProfileAccessRow] {
    guard let scan else { return [] }
    return scan.browsers.compactMap { browser in
      guard browser.application.family != .safari else { return nil }
      let persistence = profileAccess.persistence(
        for: browser.application.bundleIdentifier
      )
      let state: BrowserProfileAccessRowState
      if let persistence,
        let targetedOverlay = targetedProfileAccessOverlays[
          browser.application.bundleIdentifier
        ]
      {
        state = targetedProfileAccessState(
          targetedOverlay.browser,
          persistence: persistence
        )
      } else {
        switch browser.metadataStatus {
        case .loaded where persistence != nil:
          state = .granted(profileCount: browser.profiles.count, persistence: persistence!)
        case .accessRevoked:
          state = .accessRevoked
        case .metadataDamaged:
          state = .metadataDamaged
        case .notApplicable, .metadataAbsent, .loaded, .accessRequired:
          state = .accessNeeded
        }
      }
      return profileAccessRow(for: browser, state: state)
    }
  }

  private func profileAccessRow(
    for browser: DiscoveredBrowser,
    state: BrowserProfileAccessRowState
  ) -> BrowserProfileAccessRow? {
    guard
      let descriptor = BrowserDescriptor.descriptor(
        forBundleIdentifier: browser.application.bundleIdentifier
      ),
      descriptor.family != .safari,
      let expectedRootSuffix = descriptor.profileRoot,
      let requiredMarker = BrowserProfileRootValidator.requiredMarker(for: descriptor.family)
    else { return nil }
    return BrowserProfileAccessRow(
      bundleIdentifier: descriptor.bundleIdentifier,
      displayName: descriptor.displayName,
      family: descriptor.family,
      expectedRootSuffix: expectedRootSuffix,
      requiredMarker: requiredMarker,
      state: state,
      hasStoredGrant: profileAccess.persistence(for: descriptor.bundleIdentifier) != nil
    )
  }

  private var hasConfirmedDefaultStatus: Bool {
    defaultStatus.isDefaultBrowser
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

private struct TargetedProfileAccessOverlay {
  let browser: DiscoveredBrowser?
}

public struct MissingMailCatalog: MailDiscovering {
  public init() {}

  public func scanResult() -> MailScanResult {
    MailScanResult(applications: [], isAuthoritative: true)
  }

  public func reconcile(
    _ scan: MailScanResult,
    with config: PickViaConfig
  ) -> PickViaConfig {
    config
  }

  public func runtimeSanitizedFallback(_ config: PickViaConfig) -> PickViaConfig {
    config
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
  case routeKindMismatch
}

public enum ProfileAccessFlowError: Error, Equatable {
  case browserNotFound
  case scanNotAuthoritative
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
  sortOrder: Int? = nil,
  pendingDefaultMigration: Bool? = nil
) -> BrowserTarget {
  let capability: RouteTargetCapability
  switch target.capability {
  case .mail:
    capability = .mail
  case .browser(let options):
    capability = .browser(
      BrowserTargetOptions(
        profileIdentifier: options.profileIdentifier,
        profileDisplayName: options.profileDisplayName,
        profileIdentity: options.profileIdentity,
        profileLaunchPath: options.profileLaunchPath,
        mode: mode ?? options.mode,
        pendingDefaultMigration:
          pendingDefaultMigration ?? options.pendingDefaultMigration,
        validationError: options.validationError
      )
    )
  }
  return RouteTarget(
    id: target.id,
    applicationID: target.applicationID,
    label: label ?? target.label,
    isEnabled: isEnabled ?? target.isEnabled,
    sortOrder: sortOrder ?? target.sortOrder,
    origin: target.origin,
    availability: target.availability,
    capability: capability
  )
}

private func copy(
  _ target: BrowserTarget,
  profileIdentifier: String?,
  profileDisplayName: String?,
  profileIdentity: String?,
  profileLaunchPath: String?
) -> BrowserTarget {
  guard case .browser(let options) = target.capability else {
    return target
  }
  return RouteTarget(
    id: target.id,
    applicationID: target.applicationID,
    label: target.label,
    isEnabled: target.isEnabled,
    sortOrder: target.sortOrder,
    origin: target.origin,
    availability: target.availability,
    capability: .browser(
      BrowserTargetOptions(
        profileIdentifier: profileIdentifier,
        profileDisplayName: profileDisplayName,
        profileIdentity: profileIdentity,
        profileLaunchPath: profileLaunchPath,
        mode: options.mode,
        pendingDefaultMigration: false,
        validationError: options.validationError
      )
    )
  )
}

private func replacingRouteSlice(
  _ routeKind: RouteKind,
  in base: PickViaConfig,
  with proposed: PickViaConfig
) -> PickViaConfig {
  let proposedByID = Dictionary(
    uniqueKeysWithValues: proposed.applications
      .filter { $0.supports(routeKind) }
      .map { ($0.id, $0) }
  )
  var applications = base.applications.map { existing in
    guard let replacement = proposedByID[existing.id] else { return existing }
    return replacingCapability(
      routeKind,
      in: existing,
      from: replacement
    )
  }
  let existingApplicationIDs = Set(applications.map(\.id))
  applications.append(
    contentsOf: proposed.applications.filter {
      $0.supports(routeKind) && !existingApplicationIDs.contains($0.id)
    }
  )

  let webTargets =
    (routeKind == .web ? proposed.targets : base.targets)
    .filter { $0.routeKind == .web }
  let mailTargets =
    (routeKind == .mail ? proposed.targets : base.targets)
    .filter { $0.routeKind == .mail }
  return PickViaConfig(
    schemaVersion: proposed.schemaVersion,
    applications: applications,
    targets: webTargets + mailTargets
  )
}

private func replacingCapability(
  _ routeKind: RouteKind,
  in existing: RoutedApplication,
  from replacement: RoutedApplication
) -> RoutedApplication {
  let replacementCapability = replacement.capabilities.first {
    $0.routeKind == routeKind
  }
  var capabilities = existing.capabilities.filter {
    $0.routeKind != routeKind
  }
  if let replacementCapability {
    capabilities.append(replacementCapability)
  }
  return RoutedApplication(
    id: replacement.id,
    displayName: replacement.displayName,
    bundleIdentifier: replacement.bundleIdentifier,
    capabilities: capabilities,
    applicationURL: replacement.applicationURL,
    browserExecutableURL: replacement.browserExecutableURL
  )
}

private func targetDisplayOrder(_ lhs: RouteTarget, _ rhs: RouteTarget) -> Bool {
  if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
  return lhs.id < rhs.id
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
    $0.routeKind == .web
      && $0.applicationID == browserID
      && ($0.profileIdentifier == profileIdentifier
        || ($0.profileIdentity ?? $0.profileIdentifier) == profileIdentifier)
      && $0.origin == .detected
      && $0.availability == .available
  }
}

enum PreferenceKey {
  static let showsURLInChooser = "showsURLInChooser"
  static let chooserDensity = "chooserDensity"
  static let onboardingStep = "onboardingStep"
}

private enum Onboarding {
  static let firstStep = 1
  static let defaultBrowserStep = 3
  static let completedStep = 4
}
