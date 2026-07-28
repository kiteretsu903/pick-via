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

  public var canContinueMailReview: Bool {
    config.targets.contains { target in
      guard
        target.routeKind == .mail,
        target.isEnabled,
        target.availability == .available,
        let application = config.applications.first(where: {
          $0.id == target.applicationID
        })
      else { return false }
      return application.isAvailable(for: .mail)
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
  private var authoritativeConfig: PickViaConfig = .initial
  private var authoritativeTargetIDByRuntimeTargetID: [RouteTarget.ID: RouteTarget.ID] = [:]
  private var isLoaded = false
  private var latestAuthoritativeBrowserScan: BrowserScanResult?
  private var targetedProfileAccessOverlays: [String: TargetedProfileAccessOverlay] = [:]
  private var isAutomaticProfileAccessFlowPresented = false
  private var deferredAcceptedURLs: [URL] = []
  private var isContextualChooserSettingsSessionActive = false

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
    authoritativeConfig = loadedConfig

    let browserFallback = BrowserCatalog.runtimeSanitizedFallbackResult(loadedConfig)
    let runtimeFallback = mailCatalog.runtimeSanitizedFallback(browserFallback.config)
    let fallbackTargetIdentities = browserFallback.authoritativeTargetIDByRuntimeTargetID

    if configurationRecovery != .loadFailed {
      var persistedCandidate = loadedConfig
      var runtimeCandidate = runtimeFallback
      var candidateTargetIdentities = fallbackTargetIdentities
      var browserChanged = false
      var mailChanged = false

      let browserScan = browserCatalog.scanResult()
      if browserScan.isAuthoritative {
        recordAuthoritativeScan(browserScan)
        do {
          let reconciled = browserCatalog.reconcile(
            discovered: browserScan.browsers,
            with: persistedCandidate
          )
          let validatedRuntime = try replacingRouteSlice(
            .web,
            in: runtimeCandidate,
            with: reconciled
          ).validatedAndMigrated()
          let validatedPersisted = try replacingRouteSlice(
            .web,
            in: persistedCandidate,
            with: reconciled
          ).validatedAndMigrated()
          browserChanged = validatedPersisted != persistedCandidate
          runtimeCandidate = validatedRuntime
          persistedCandidate = validatedPersisted
          candidateTargetIdentities = replacingTargetIdentityMapping(
            for: .web,
            current: candidateTargetIdentities,
            runtime: validatedRuntime
          )
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
          let reconciled = mailCatalog.reconcile(mailScan, with: persistedCandidate)
          let validatedRuntime = try replacingRouteSlice(
            .mail,
            in: runtimeCandidate,
            with: reconciled
          ).validatedAndMigrated()
          let validatedPersisted = try replacingRouteSlice(
            .mail,
            in: persistedCandidate,
            with: reconciled
          ).validatedAndMigrated()
          mailChanged = validatedPersisted != persistedCandidate
          runtimeCandidate = validatedRuntime
          persistedCandidate = validatedPersisted
          candidateTargetIdentities = replacingTargetIdentityMapping(
            for: .mail,
            current: candidateTargetIdentities,
            runtime: validatedRuntime
          )
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
          try configStore.save(persistedCandidate)
          authoritativeConfig = persistedCandidate
          config = runtimeCandidate
          authoritativeTargetIDByRuntimeTargetID = candidateTargetIdentities
        } catch {
          config = runtimeFallback
          authoritativeTargetIDByRuntimeTargetID = fallbackTargetIdentities
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
        authoritativeConfig = persistedCandidate
        config = runtimeCandidate
        authoritativeTargetIDByRuntimeTargetID = candidateTargetIdentities
      }
      targetSnapshot?.publish(config)
    } else {
      config = .initial
      authoritativeTargetIDByRuntimeTargetID = [:]
    }
    showsURLInChooser = preferences.bool(forKey: PreferenceKey.showsURLInChooser) ?? true
    chooserDensity = .fromPersistedValue(
      preferences.integer(forKey: PreferenceKey.chooserDensity)
    )
    launchesAtLogin = loginItem.isEnabled
    defaultStatus = defaultBrowser.status()
    let persistedVersion =
      preferences.integer(forKey: PreferenceKey.onboardingVersion) ?? 1
    let persistedStep =
      preferences.integer(forKey: PreferenceKey.onboardingStep) ?? Onboarding.firstStep
    onboardingStep = normalizedOnboardingStep(
      persistedStep,
      persistedVersion: persistedVersion
    )
    if persistedVersion != Onboarding.currentVersion {
      preferences.set(onboardingStep, forKey: PreferenceKey.onboardingStep)
      preferences.set(
        Onboarding.currentVersion,
        forKey: PreferenceKey.onboardingVersion
      )
    } else if onboardingStep != persistedStep {
      preferences.set(onboardingStep, forKey: PreferenceKey.onboardingStep)
    }
    isLoaded = true
  }

  public func advanceOnboarding() {
    switch onboardingStep {
    case Onboarding.firstStep:
      onboardingStep = Onboarding.browserReviewStep
    case Onboarding.browserReviewStep where canContinueOnboardingReview:
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
      try commitAuthoritativeScan(scan, refreshRouting: true)
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
      let reconciled = mailCatalog.reconcile(scan, with: authoritativeConfig)
      let authoritativeUpdate = try replacingRouteSlice(
        .mail,
        in: authoritativeConfig,
        with: reconciled
      ).validatedAndMigrated()
      let runtimeUpdate = try replacingRouteSlice(
        .mail,
        in: config,
        with: reconciled
      ).validatedAndMigrated()
      try configStore.save(authoritativeUpdate)
      authoritativeConfig = authoritativeUpdate
      config = runtimeUpdate
      authoritativeTargetIDByRuntimeTargetID = replacingTargetIdentityMapping(
        for: .mail,
        current: authoritativeTargetIDByRuntimeTargetID,
        runtime: runtimeUpdate
      )
      targetSnapshot?.publish(runtimeUpdate)
      refreshRoutingUnlessContextualSettings()
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
      try commitAuthoritativeScan(scan, refreshRouting: true)
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
      try commitAuthoritativeScan(scan, refreshRouting: true)
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
    onboardingStep = normalizedOnboardingStep(
      onboardingStep,
      persistedVersion: Onboarding.currentVersion
    )
  }

  public func settingsDidClose() {
    isContextualChooserSettingsSessionActive = false
    routing.refreshCurrent()
    if configurationRecovery == .recoveredCorruption {
      configurationRecovery = .none
    }
  }

  public func chooserSettingsDidOpen(for _: RouteKind) {
    isContextualChooserSettingsSessionActive = true
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

  public func previewChooser(kind: RouteKind) {
    guard canPresentOrdinaryAppSurface else { return }
    let previewURL =
      switch kind {
      case .web:
        URL(string: "https://pickvia.invalid/chooser-preview")!
      case .mail:
        URL(string: "mailto:pickvia-preview@invalid")!
      }
    routing.preview(previewURL)
  }

  public func requestDefaultBrowser() async {
    guard canRequestDefaultBrowser else { return }

    // Status is authoritative; refresh it even when the consent API throws.
    _ = try? await defaultBrowser.requestDefault(for: ["http", "https"])
    refreshDefaultStatus()

    if hasConfirmedDefaultStatus {
      if onboardingStep == Onboarding.defaultBrowserStep {
        onboardingStep = Onboarding.mailReviewStep
      }
      errorMessage = nil
    } else {
      if onboardingStep >= Onboarding.completedStep {
        onboardingStep = Onboarding.defaultBrowserStep
      }
      errorMessage =
        "PickVia was not made the default browser for HTTP and HTTPS. You can try again."
    }
  }

  public func continueMailReview() {
    guard
      onboardingStep == Onboarding.mailReviewStep,
      canContinueMailReview
    else { return }
    onboardingStep = Onboarding.defaultMailStep
  }

  public func requestDefaultMail() async {
    _ = try? await defaultBrowser.requestDefault(for: ["mailto"])
    refreshDefaultStatus()

    guard onboardingStep == Onboarding.defaultMailStep else { return }
    if defaultStatus.mailto == .isDefault {
      onboardingStep = Onboarding.completedStep
      mailErrorMessage = nil
    } else {
      mailErrorMessage =
        "PickVia was not made the default mail app. You can try again."
    }
  }

  public func skipMailSetup() {
    guard
      onboardingStep == Onboarding.mailReviewStep
        || onboardingStep == Onboarding.defaultMailStep
    else { return }
    mailErrorMessage = nil
    onboardingStep = Onboarding.completedStep
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
    try persistTargetUpdates([
      TargetUpdate(runtimeTargetID: id, edit: .rename(label))
    ])
  }

  public func setTargetEnabled(id: BrowserTarget.ID, isEnabled: Bool) throws {
    try persistTargetUpdates([
      TargetUpdate(
        runtimeTargetID: id,
        edit: .setEnabled(isEnabled, clearsPendingDefaultMigration: true)
      )
    ])
  }

  public func setTargetMode(id: BrowserTarget.ID, mode: BrowserMode) throws {
    guard let target = config.targets.first(where: { $0.id == id }) else {
      throw TargetEditingError.targetNotFound
    }
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
    try persistTargetUpdates([
      TargetUpdate(runtimeTargetID: id, edit: .setBrowserMode(mode))
    ])
  }

  public func setTargetProfile(
    id: BrowserTarget.ID,
    profileIdentifier: String?
  ) throws {
    guard let target = config.targets.first(where: { $0.id == id }) else {
      throw TargetEditingError.targetNotFound
    }
    guard target.routeKind == .web else {
      throw TargetEditingError.routeKindMismatch
    }
    guard target.origin == .manual || target.profileIdentifier == profileIdentifier else {
      throw TargetEditingError.detectedTargetIdentityIsImmutable
    }
    guard let browser = supportedAvailableBrowser(id: target.browserID, in: config) else {
      throw TargetEditingError.browserUnavailableOrUnsupported
    }
    if target.origin == .detected {
      try persistTargetUpdates([
        TargetUpdate(
          runtimeTargetID: id,
          edit: .clearBrowserPendingDefaultMigration
        )
      ])
      return
    }

    let selectedRuntimeTargetID: RouteTarget.ID?
    if browser.family == .safari {
      guard profileIdentifier == nil else { throw TargetEditingError.invalidProfileIdentity }
      selectedRuntimeTargetID = nil
    } else if profileIdentifier == nil {
      selectedRuntimeTargetID = nil
    } else {
      guard
        let profileIdentifier,
        !profileIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let candidate = detectedProfileTarget(
          browserID: browser.id,
          profileIdentifier: profileIdentifier,
          in: config
        )
      else { throw TargetEditingError.invalidProfileIdentity }
      selectedRuntimeTargetID = candidate.id
    }

    try persistTargetUpdates([
      TargetUpdate(
        runtimeTargetID: id,
        edit: .setBrowserProfile(selectedRuntimeTargetID: selectedRuntimeTargetID)
      )
    ])
  }

  public func setMailTargetEnabled(
    id: RouteTarget.ID,
    isEnabled: Bool
  ) throws {
    guard let target = config.targets.first(where: { $0.id == id }) else {
      throw TargetEditingError.targetNotFound
    }
    guard target.routeKind == .mail else {
      throw TargetEditingError.routeKindMismatch
    }
    try persistTargetUpdates([
      TargetUpdate(
        runtimeTargetID: id,
        edit: .setEnabled(isEnabled, clearsPendingDefaultMigration: false)
      )
    ])
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
    try persistTargetUpdates(
      orderedMail.enumerated().map { index, target in
        TargetUpdate(
          runtimeTargetID: target.id,
          edit: .setSortOrder(index, clearsPendingDefaultMigration: false)
        )
      },
      ordering: .mail,
      by: orderedMail.map(\.id)
    )
  }

  public func moveTargets(fromOffsets offsets: IndexSet, toOffset destination: Int) throws {
    var ordered = config.targets.filter { $0.routeKind == .web }.sorted(by: targetDisplayOrder)
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
    try persistTargetUpdates(
      ordered.enumerated().map { index, target in
        TargetUpdate(
          runtimeTargetID: target.id,
          edit: .setSortOrder(
            index,
            clearsPendingDefaultMigration:
              originalIndexByID[target.id] != index || movedIDs.contains(target.id)
          )
        )
      },
      ordering: .web,
      by: ordered.map(\.id)
    )
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

    let authoritativeSelectedProfile: BrowserTarget?
    if let selectedProfile {
      guard
        let authoritativeSelectedID =
          authoritativeTargetIDByRuntimeTargetID[selectedProfile.id],
        let target = authoritativeConfig.targets.first(where: {
          $0.id == authoritativeSelectedID
        })
      else { throw TargetEditingError.targetNotFound }
      authoritativeSelectedProfile = target
    } else {
      authoritativeSelectedProfile = nil
    }

    let id = UUID().uuidString
    let sortOrder =
      (config.targets.lazy.filter { $0.routeKind == .web }.map(\.sortOrder).max() ?? -1) + 1
    let runtimeTarget = BrowserTarget(
      id: id,
      browserID: browserID,
      label: label,
      profileIdentifier: selectedProfile?.profileIdentifier,
      profileDisplayName: selectedProfile?.profileDisplayName,
      profileIdentity: selectedProfile?.profileIdentity,
      profileLaunchPath: selectedProfile?.profileLaunchPath,
      mode: mode,
      isEnabled: true,
      sortOrder: sortOrder,
      origin: .manual,
      availability: .available
    )
    let authoritativeTarget = BrowserTarget(
      id: id,
      browserID: browserID,
      label: label,
      profileIdentifier: authoritativeSelectedProfile?.profileIdentifier,
      profileDisplayName: authoritativeSelectedProfile?.profileDisplayName,
      profileIdentity: authoritativeSelectedProfile?.profileIdentity,
      profileLaunchPath: authoritativeSelectedProfile?.profileLaunchPath,
      mode: mode,
      isEnabled: true,
      sortOrder: sortOrder,
      origin: .manual,
      availability: .available
    )
    try persistInsertedTarget(
      runtime: runtimeTarget,
      authoritative: authoritativeTarget
    )
    return id
  }

  public func removeManualTarget(id: BrowserTarget.ID) throws {
    guard let target = config.targets.first(where: { $0.id == id }) else {
      throw TargetEditingError.targetNotFound
    }
    guard target.origin == .manual else { throw TargetEditingError.detectedTargetCannotBeRemoved }
    try persistRemovedTarget(runtimeTargetID: id)
  }

  private func commitAuthoritativeScan(
    _ scan: BrowserScanResult,
    refreshRouting: Bool
  ) throws {
    let reconciled = browserCatalog.reconcile(
      discovered: scan.browsers,
      with: authoritativeConfig
    )
    let authoritativeUpdate = try replacingRouteSlice(
      .web,
      in: authoritativeConfig,
      with: reconciled
    ).validatedAndMigrated()
    let runtimeUpdate = try replacingRouteSlice(
      .web,
      in: config,
      with: reconciled
    ).validatedAndMigrated()
    try configStore.save(authoritativeUpdate)
    authoritativeConfig = authoritativeUpdate
    config = runtimeUpdate
    authoritativeTargetIDByRuntimeTargetID = replacingTargetIdentityMapping(
      for: .web,
      current: authoritativeTargetIDByRuntimeTargetID,
      runtime: runtimeUpdate
    )
    targetSnapshot?.publish(runtimeUpdate)
    if refreshRouting {
      refreshRoutingUnlessContextualSettings()
    }
  }

  private func refreshRoutingUnlessContextualSettings() {
    guard !isContextualChooserSettingsSessionActive else { return }
    routing.refreshCurrent()
  }

  private func persistTargetUpdates(
    _ updates: [TargetUpdate],
    ordering routeKind: RouteKind? = nil,
    by orderedRuntimeTargetIDs: [RouteTarget.ID] = []
  ) throws {
    var runtimeTargets = config.targets
    var authoritativeTargets = authoritativeConfig.targets
    for update in updates {
      guard
        let runtimeIndex = runtimeTargets.firstIndex(where: {
          $0.id == update.runtimeTargetID
        }),
        let authoritativeTargetID =
          authoritativeTargetIDByRuntimeTargetID[update.runtimeTargetID],
        let authoritativeIndex = authoritativeTargets.firstIndex(where: {
          $0.id == authoritativeTargetID
        })
      else { throw TargetEditingError.targetNotFound }

      let currentRuntimeTarget = runtimeTargets[runtimeIndex]
      let currentAuthoritativeTarget = authoritativeTargets[authoritativeIndex]
      guard
        currentAuthoritativeTarget.routeKind == currentRuntimeTarget.routeKind,
        currentAuthoritativeTarget.applicationID == currentRuntimeTarget.applicationID
      else { throw TargetEditingError.targetNotFound }

      runtimeTargets[runtimeIndex] = try applying(
        update.edit,
        to: currentRuntimeTarget,
        in: config,
        role: .runtime
      )
      authoritativeTargets[authoritativeIndex] = try applying(
        update.edit,
        to: currentAuthoritativeTarget,
        in: authoritativeConfig,
        role: .authoritative
      )
    }

    if let routeKind {
      let orderedRuntimeTargets = try orderedRuntimeTargetIDs.map { runtimeTargetID in
        guard
          let target = runtimeTargets.first(where: { $0.id == runtimeTargetID }),
          target.routeKind == routeKind
        else { throw TargetEditingError.targetNotFound }
        return target
      }
      let orderedAuthoritativeTargets = try orderedRuntimeTargetIDs.map { runtimeTargetID in
        guard
          let authoritativeTargetID =
            authoritativeTargetIDByRuntimeTargetID[runtimeTargetID],
          let target = authoritativeTargets.first(where: {
            $0.id == authoritativeTargetID
          }),
          target.routeKind == routeKind
        else { throw TargetEditingError.targetNotFound }
        return target
      }
      let otherRuntimeTargets = runtimeTargets.filter {
        $0.routeKind != routeKind
      }
      let otherAuthoritativeTargets = authoritativeTargets.filter {
        $0.routeKind != routeKind
      }
      if routeKind == .web {
        runtimeTargets = orderedRuntimeTargets + otherRuntimeTargets
        authoritativeTargets = orderedAuthoritativeTargets + otherAuthoritativeTargets
      } else {
        runtimeTargets = otherRuntimeTargets + orderedRuntimeTargets
        authoritativeTargets = otherAuthoritativeTargets + orderedAuthoritativeTargets
      }
    }

    try commitTargets(
      runtime: runtimeTargets,
      authoritative: authoritativeTargets,
      identities: authoritativeTargetIDByRuntimeTargetID
    )
  }

  private func persistInsertedTarget(
    runtime runtimeTarget: RouteTarget,
    authoritative authoritativeTarget: RouteTarget
  ) throws {
    guard
      runtimeTarget.id == authoritativeTarget.id,
      runtimeTarget.routeKind == authoritativeTarget.routeKind,
      runtimeTarget.applicationID == authoritativeTarget.applicationID
    else { throw TargetEditingError.targetNotFound }

    var identities = authoritativeTargetIDByRuntimeTargetID
    identities[runtimeTarget.id] = authoritativeTarget.id
    try commitTargets(
      runtime: config.targets + [runtimeTarget],
      authoritative: authoritativeConfig.targets + [authoritativeTarget],
      identities: identities
    )
  }

  private func persistRemovedTarget(runtimeTargetID: RouteTarget.ID) throws {
    guard
      let currentRuntimeTarget = config.targets.first(where: {
        $0.id == runtimeTargetID
      }),
      let authoritativeTargetID =
        authoritativeTargetIDByRuntimeTargetID[runtimeTargetID],
      let currentAuthoritativeTarget = authoritativeConfig.targets.first(where: {
        $0.id == authoritativeTargetID
      }),
      currentAuthoritativeTarget.routeKind == currentRuntimeTarget.routeKind,
      currentAuthoritativeTarget.applicationID == currentRuntimeTarget.applicationID
    else { throw TargetEditingError.targetNotFound }

    var identities = authoritativeTargetIDByRuntimeTargetID
    identities[runtimeTargetID] = nil
    try commitTargets(
      runtime: config.targets.filter { $0.id != runtimeTargetID },
      authoritative: authoritativeConfig.targets.filter {
        $0.id != authoritativeTargetID
      },
      identities: identities
    )
  }

  private func commitTargets(
    runtime runtimeTargets: [RouteTarget],
    authoritative authoritativeTargets: [RouteTarget],
    identities: [RouteTarget.ID: RouteTarget.ID]
  ) throws {
    let canonicalizedPersistence = try canonicalizingLegacyFirefoxPersistence(
      runtime: runtimeTargets,
      authoritative: authoritativeTargets,
      identities: identities
    )
    let runtimeUpdate = try PickViaConfig(
      schemaVersion: config.schemaVersion,
      applications: config.applications,
      targets: runtimeTargets
    ).validatedAndMigrated()
    let authoritativeUpdate = try PickViaConfig(
      schemaVersion: authoritativeConfig.schemaVersion,
      applications: authoritativeConfig.applications,
      targets: canonicalizedPersistence.targets
    ).validatedAndMigrated()
    try configStore.save(authoritativeUpdate)
    authoritativeConfig = authoritativeUpdate
    config = runtimeUpdate
    authoritativeTargetIDByRuntimeTargetID = canonicalizedPersistence.identities
    targetSnapshot?.publish(runtimeUpdate)
    errorMessage = nil
    mailErrorMessage = nil
  }

  private func canonicalizingLegacyFirefoxPersistence(
    runtime runtimeTargets: [RouteTarget],
    authoritative authoritativeTargets: [RouteTarget],
    identities: [RouteTarget.ID: RouteTarget.ID]
  ) throws -> (
    targets: [RouteTarget],
    identities: [RouteTarget.ID: RouteTarget.ID]
  ) {
    let firefoxApplicationIDs = Set(
      authoritativeConfig.applications.compactMap { application in
        application.browserFamily == .firefox ? application.id : nil
      }
    )
    let runtimeTargetsByID = Dictionary(
      uniqueKeysWithValues: runtimeTargets.map { ($0.id, $0) }
    )
    var runtimeTargetIDByAuthoritativeTargetID: [RouteTarget.ID: RouteTarget.ID] = [:]
    for (runtimeTargetID, authoritativeTargetID) in identities {
      guard runtimeTargetIDByAuthoritativeTargetID[authoritativeTargetID] == nil else {
        throw TargetEditingError.targetNotFound
      }
      runtimeTargetIDByAuthoritativeTargetID[authoritativeTargetID] = runtimeTargetID
    }

    let needsCanonicalization = authoritativeTargets.map { target in
      guard
        target.routeKind == .web,
        firefoxApplicationIDs.contains(target.applicationID)
      else { return false }
      return !FirefoxPersistencePolicy.isPersistenceSafe(target)
    }
    var usedTargetIDs = Set(
      zip(authoritativeTargets, needsCanonicalization).compactMap {
        target, needsCanonicalization in
        needsCanonicalization ? nil : target.id
      }
    )
    var canonicalTargetIDByOriginalTargetID: [RouteTarget.ID: RouteTarget.ID] = [:]
    var canonicalTargets: [RouteTarget] = []

    for (index, target) in authoritativeTargets.enumerated() {
      guard
        target.routeKind == .web,
        firefoxApplicationIDs.contains(target.applicationID)
      else {
        canonicalTargetIDByOriginalTargetID[target.id] = target.id
        canonicalTargets.append(target)
        continue
      }

      guard needsCanonicalization[index] else {
        canonicalTargetIDByOriginalTargetID[target.id] = target.id
        canonicalTargets.append(target)
        continue
      }
      guard
        let runtimeTargetID = runtimeTargetIDByAuthoritativeTargetID[target.id],
        let runtimeTarget = runtimeTargetsByID[runtimeTargetID],
        runtimeTarget.routeKind == target.routeKind,
        runtimeTarget.applicationID == target.applicationID
      else { throw TargetEditingError.targetNotFound }

      let canonicalIdentity: String?
      if let targetIdentity = target.profileIdentity,
        !FirefoxProfileIdentity.isOpaqueIdentifier(targetIdentity)
      {
        if let runtimeIdentity = runtimeTarget.profileIdentity {
          guard FirefoxProfileIdentity.isOpaqueIdentifier(runtimeIdentity) else {
            throw TargetEditingError.invalidProfileIdentity
          }
        }
        canonicalIdentity = runtimeTarget.profileIdentity
      } else {
        canonicalIdentity = target.profileIdentity
      }
      var shape = FirefoxPersistencePolicy.canonicalShape(
        for: target,
        profileIdentity: canonicalIdentity
      )

      let canonicalID: RouteTarget.ID
      if FirefoxPersistencePolicy.isForbiddenTargetID(shape.targetID) {
        canonicalID = uniquePersistenceTargetID(
          preferred: runtimeTarget.id,
          legacyTargetID: target.id,
          usedTargetIDs: &usedTargetIDs
        )
      } else if usedTargetIDs.insert(shape.targetID).inserted {
        canonicalID = shape.targetID
      } else if target.origin == .detected {
        let collisionIdentity = uniquePersistenceProfileIdentity(
          applicationID: target.applicationID,
          mode: target.mode,
          legacyTargetID: target.id,
          usedTargetIDs: &usedTargetIDs
        )
        let collisionShape = FirefoxPersistencePolicy.canonicalShape(
          for: target,
          profileIdentity: collisionIdentity
        )
        shape = FirefoxPersistenceShape(
          targetID: collisionShape.targetID,
          profileIdentifier: collisionShape.profileIdentifier,
          profileDisplayName: collisionShape.profileDisplayName,
          profileIdentity: collisionShape.profileIdentity,
          availability: shape.availability
        )
        canonicalID = shape.targetID
      } else {
        canonicalID = uniquePersistenceTargetID(
          preferred: runtimeTarget.id,
          legacyTargetID: target.id,
          usedTargetIDs: &usedTargetIDs
        )
      }

      let canonicalTarget = RouteTarget(
        id: canonicalID,
        applicationID: target.applicationID,
        label: target.label,
        isEnabled: target.isEnabled,
        sortOrder: target.sortOrder,
        origin: target.origin,
        availability: shape.availability,
        capability: .browser(
          BrowserTargetOptions(
            profileIdentifier: shape.profileIdentifier,
            profileDisplayName: shape.profileDisplayName,
            profileIdentity: shape.profileIdentity,
            profileLaunchPath: target.profileLaunchPath,
            mode: target.mode,
            pendingDefaultMigration: target.pendingDefaultMigration,
            validationError: target.validationError
          )
        )
      )
      guard FirefoxPersistencePolicy.isPersistenceSafe(canonicalTarget) else {
        throw TargetEditingError.invalidProfileIdentity
      }
      canonicalTargetIDByOriginalTargetID[target.id] = canonicalTarget.id
      canonicalTargets.append(canonicalTarget)
    }

    let canonicalIdentities = try Dictionary(
      uniqueKeysWithValues: identities.map { runtimeTargetID, authoritativeTargetID in
        guard
          let canonicalTargetID =
            canonicalTargetIDByOriginalTargetID[authoritativeTargetID]
        else { throw TargetEditingError.targetNotFound }
        return (runtimeTargetID, canonicalTargetID)
      }
    )
    return (canonicalTargets, canonicalIdentities)
  }

  private func uniquePersistenceTargetID(
    preferred: RouteTarget.ID,
    legacyTargetID: RouteTarget.ID,
    usedTargetIDs: inout Set<RouteTarget.ID>
  ) -> RouteTarget.ID {
    guard !usedTargetIDs.contains(preferred) else {
      var attempt = 0
      while true {
        let seed = "\(legacyTargetID)#persistence#\(attempt)"
        let identifier = FirefoxProfileIdentity.identifier(
          for: URL(fileURLWithPath: seed, isDirectory: true)
        )
        let candidate = "firefox-persisted-target|\(identifier)"
        attempt += 1
        guard usedTargetIDs.insert(candidate).inserted else { continue }
        return candidate
      }
    }
    usedTargetIDs.insert(preferred)
    return preferred
  }

  private func uniquePersistenceProfileIdentity(
    applicationID: BrowserApplication.ID,
    mode: BrowserMode,
    legacyTargetID: RouteTarget.ID,
    usedTargetIDs: inout Set<RouteTarget.ID>
  ) -> String {
    var attempt = 0
    while true {
      let seed = "\(legacyTargetID)#persistence-profile#\(attempt)"
      let identity = FirefoxProfileIdentity.identifier(
        for: URL(fileURLWithPath: seed, isDirectory: true)
      )
      let candidate = BrowserCatalog.targetID(
        bundleIdentifier: applicationID,
        profileIdentifier: identity,
        mode: mode
      )
      attempt += 1
      guard usedTargetIDs.insert(candidate).inserted else { continue }
      return identity
    }
  }

  private func applying(
    _ edit: TargetSemanticEdit,
    to target: RouteTarget,
    in sourceConfig: PickViaConfig,
    role: TargetConfigurationRole
  ) throws -> RouteTarget {
    var label = target.label
    var isEnabled = target.isEnabled
    var sortOrder = target.sortOrder
    var capability = target.capability

    switch edit {
    case .rename(let value):
      label = value
      capability = clearingPendingDefaultMigration(in: capability)
    case .setEnabled(let value, let clearsPendingDefaultMigration):
      isEnabled = value
      if clearsPendingDefaultMigration {
        capability = clearingPendingDefaultMigration(in: capability)
      }
    case .setSortOrder(let value, let clearsPendingDefaultMigration):
      sortOrder = value
      if clearsPendingDefaultMigration {
        capability = clearingPendingDefaultMigration(in: capability)
      }
    case .setBrowserMode(let mode):
      guard case .browser(let options) = capability else {
        throw TargetEditingError.routeKindMismatch
      }
      capability = .browser(
        BrowserTargetOptions(
          profileIdentifier: options.profileIdentifier,
          profileDisplayName: options.profileDisplayName,
          profileIdentity: options.profileIdentity,
          profileLaunchPath: options.profileLaunchPath,
          mode: mode,
          pendingDefaultMigration: false,
          validationError: options.validationError
        )
      )
    case .clearBrowserPendingDefaultMigration:
      guard case .browser = capability else {
        throw TargetEditingError.routeKindMismatch
      }
      capability = clearingPendingDefaultMigration(in: capability)
    case .setBrowserProfile(let selectedRuntimeTargetID):
      guard case .browser(let options) = capability else {
        throw TargetEditingError.routeKindMismatch
      }
      let selectedTarget: RouteTarget?
      if let selectedRuntimeTargetID {
        let selectedTargetID: RouteTarget.ID
        switch role {
        case .runtime:
          selectedTargetID = selectedRuntimeTargetID
        case .authoritative:
          guard
            let authoritativeID =
              authoritativeTargetIDByRuntimeTargetID[selectedRuntimeTargetID]
          else { throw TargetEditingError.targetNotFound }
          selectedTargetID = authoritativeID
        }
        guard
          let candidate = sourceConfig.targets.first(where: {
            $0.id == selectedTargetID
          }),
          candidate.routeKind == .web,
          candidate.applicationID == target.applicationID,
          candidate.origin == .detected,
          candidate.availability == .available
        else { throw TargetEditingError.invalidProfileIdentity }
        selectedTarget = candidate
      } else {
        selectedTarget = nil
      }
      capability = .browser(
        BrowserTargetOptions(
          profileIdentifier: selectedTarget?.profileIdentifier,
          profileDisplayName: selectedTarget?.profileDisplayName,
          profileIdentity: selectedTarget?.profileIdentity,
          profileLaunchPath: selectedTarget?.profileLaunchPath,
          mode: options.mode,
          pendingDefaultMigration: false,
          validationError: options.validationError
        )
      )
    }

    return RouteTarget(
      id: target.id,
      applicationID: target.applicationID,
      label: label,
      isEnabled: isEnabled,
      sortOrder: sortOrder,
      origin: target.origin,
      availability: target.availability,
      capability: capability
    )
  }

  private func clearingPendingDefaultMigration(
    in capability: RouteTargetCapability
  ) -> RouteTargetCapability {
    guard case .browser(let options) = capability else { return capability }
    return .browser(
      BrowserTargetOptions(
        profileIdentifier: options.profileIdentifier,
        profileDisplayName: options.profileDisplayName,
        profileIdentity: options.profileIdentity,
        profileLaunchPath: options.profileLaunchPath,
        mode: options.mode,
        pendingDefaultMigration: false,
        validationError: options.validationError
      )
    )
  }

  private func replacingTargetIdentityMapping(
    for routeKind: RouteKind,
    current: [RouteTarget.ID: RouteTarget.ID],
    runtime: PickViaConfig
  ) -> [RouteTarget.ID: RouteTarget.ID] {
    let retainedRuntimeTargetIDs = Set(
      runtime.targets.lazy.filter { $0.routeKind != routeKind }.map(\.id)
    )
    var result = current.filter {
      retainedRuntimeTargetIDs.contains($0.key)
    }
    for target in runtime.targets where target.routeKind == routeKind {
      result[target.id] = target.id
    }
    return result
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

  private func normalizedOnboardingStep(
    _ persistedStep: Int,
    persistedVersion: Int
  ) -> Int {
    if persistedVersion < Onboarding.currentVersion {
      let legacyStep = min(
        max(persistedStep, Onboarding.firstStep),
        4
      )
      if legacyStep == 4 {
        return hasConfirmedDefaultStatus
          ? Onboarding.completedStep
          : Onboarding.defaultBrowserStep
      }
      return legacyStep
    }

    let bounded = min(
      max(persistedStep, Onboarding.firstStep),
      Onboarding.completedStep
    )
    if bounded >= Onboarding.mailReviewStep && !hasConfirmedDefaultStatus {
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

private struct TargetUpdate {
  let runtimeTargetID: RouteTarget.ID
  let edit: TargetSemanticEdit
}

private enum TargetSemanticEdit {
  case rename(String)
  case setEnabled(Bool, clearsPendingDefaultMigration: Bool)
  case setSortOrder(Int, clearsPendingDefaultMigration: Bool)
  case setBrowserMode(BrowserMode)
  case clearBrowserPendingDefaultMigration
  case setBrowserProfile(selectedRuntimeTargetID: RouteTarget.ID?)
}

private enum TargetConfigurationRole {
  case runtime
  case authoritative
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
  let metadata =
    routeKind == .mail && existing.supports(.web)
    ? existing : replacement
  return RoutedApplication(
    id: metadata.id,
    displayName: metadata.displayName,
    bundleIdentifier: metadata.bundleIdentifier,
    capabilities: capabilities,
    applicationURL: metadata.applicationURL,
    browserExecutableURL: metadata.browserExecutableURL
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
  static let onboardingVersion = "onboardingVersion"
  static let onboardingStep = "onboardingStep"
}

private enum Onboarding {
  static let currentVersion = 2
  static let firstStep = 1
  static let browserReviewStep = 2
  static let defaultBrowserStep = 3
  static let mailReviewStep = 4
  static let defaultMailStep = 5
  static let completedStep = 6
}
