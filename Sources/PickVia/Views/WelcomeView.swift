import AppKit
import PickViaCore
import SwiftUI

public struct WelcomeView: View {
  @AppStorage(L10n.preferenceKey) private var localizationSelection = L10n.system
  @Environment(AppModel.self) private var model
  @Environment(\.profileAccessPresenter) private var profileAccessPresenter
  @Environment(\.dismissWindow) private var dismissWindow

  public init() {}

  public var body: some View {
    let _ = localizationSelection
    Group {
      if lifecycle.shouldShowContent(isOnboardingComplete: model.isOnboardingComplete) {
        ViewThatFits(in: .vertical) {
          welcomeContent.fixedSize(horizontal: false, vertical: true)
          ScrollView(.vertical) { welcomeContent }
        }
        .frame(maxHeight: max(240, LocalizationLayout.availableHeight - 80))
      } else {
        Color.clear
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
      }
    }
    .onAppear {
      lifecycle.synchronize(isOnboardingComplete: model.isOnboardingComplete)
    }
    .onChange(of: model.isOnboardingComplete) { _, isComplete in
      lifecycle.synchronize(isOnboardingComplete: isComplete)
    }
  }

  private var lifecycle: WelcomeLifecycle {
    WelcomeLifecycle(dismiss: { dismissWindow(id: "welcome") })
  }

  private var welcomeContent: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(L10n.tr("Welcome to PickVia"))
        .font(.largeTitle.bold())

      if let step = welcomeStep(for: model.onboardingStep) {
        switch step {
        case .discovery:
          discoveryStep
        case .browserReview:
          reviewStep
        case .defaultBrowser:
          defaultBrowserStep
        case .mailReview:
          mailReviewStep
        case .defaultMail:
          defaultMailStep
        }
      }

      if let errorMessage = onboardingErrorMessage {
        Label(L10n.tr(errorMessage), systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
    }
    .padding(32)
    .frame(width: min(560, LocalizationLayout.availableWidth - 32))
    .frame(minHeight: 360, alignment: .topLeading)
  }

  private var discoveryStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(L10n.tr("Discover browsers"), systemImage: "sparkle.magnifyingglass")
        .font(.title2.bold())
      LabeledContent(
        L10n.tr("Browsers"), value: String(model.browsers.filter(\.isAvailable).count)
      )
      .foregroundStyle(.secondary)
      HStack {
        Button(L10n.tr("Scan Again")) { rescan() }
        Spacer()
        Button(L10n.tr("Continue")) { model.advanceOnboarding() }
          .buttonStyle(.borderedProminent)
      }
    }
  }

  private var reviewStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(L10n.tr("Review browser targets"), systemImage: "checklist")
        .font(.title2.bold())
      Text(L10n.tr("Choose which profiles and modes should appear when you open a link."))
        .foregroundStyle(.secondary)
      List(
        model.targets.filter { $0.routeKind == .web }.sorted {
          $0.sortOrder < $1.sortOrder
        }
      ) { target in
        HStack {
          Text(
            target.localizedLabel(
              applicationName: model.browsers.first { $0.id == target.applicationID }?.displayName
                ?? target.label))
          Spacer()
          Text(target.isEnabled ? L10n.tr("Enabled") : L10n.tr("Hidden"))
            .foregroundStyle(.secondary)
        }
      }
      .frame(minHeight: 150)
      HStack {
        Button(L10n.tr("Rescan")) { rescan() }
        Spacer()
        Button(L10n.tr("Continue")) {
          advanceOnboardingAndPresentProfileAccess(
            model: model,
            profileAccessPresenter: profileAccessPresenter
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canContinueOnboardingReview)
      }
    }
  }

  private var defaultBrowserStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(L10n.tr("Make PickVia your default browser"), systemImage: "checkmark.seal")
        .font(.title2.bold())
      Text(L10n.tr("macOS asks separately for permission to handle HTTP and HTTPS links."))
        .foregroundStyle(.secondary)
      BrowserDefaultStatusRows(status: model.defaultStatus)
      HStack {
        Spacer()
        Button(L10n.tr("Set as Default")) {
          Task { await model.requestDefaultBrowser() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canRequestDefaultBrowser)
      }
    }
  }

  private var mailReviewStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(L10n.tr("Review mail apps"), systemImage: "envelope.badge")
        .font(.title2.bold())
      Text(L10n.tr("Choose which mail applications should appear when you open a mail link."))
        .foregroundStyle(.secondary)
      List(mailReviewRows) { row in
        HStack(spacing: 10) {
          applicationIcon(row.application)
          Text(row.application.displayName)
          Spacer()
          Text(row.target.isEnabled ? L10n.tr("Enabled") : L10n.tr("Hidden"))
            .foregroundStyle(.secondary)
        }
      }
      .frame(minHeight: 150)
      HStack {
        Button(L10n.tr("Rescan")) { try? model.rescanMailApplications() }
        Spacer()
        Button(L10n.tr("Skip Mail Setup")) { model.skipMailSetup() }
        Button(L10n.tr("Continue")) { model.continueMailReview() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canContinueMailReview)
      }
    }
  }

  private var defaultMailStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(L10n.tr("Make PickVia your default mail app"), systemImage: "checkmark.seal")
        .font(.title2.bold())
      Text(L10n.tr("macOS asks for permission to handle mail links."))
        .foregroundStyle(.secondary)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
        DefaultStatusRow(scheme: "MAILTO", status: model.defaultStatus.mailto)
      }
      HStack {
        Spacer()
        Button(L10n.tr("Skip Mail Setup")) { model.skipMailSetup() }
        Button(L10n.tr("Set as Default")) {
          Task { await model.requestDefaultMail() }
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  private var mailReviewRows: [MailSettingsRow] {
    makeMailSettingsRows(
      applications: model.mailApplications,
      targets: model.mailTargets
    )
  }

  private var onboardingErrorMessage: String? {
    switch welcomeStep(for: model.onboardingStep) {
    case .mailReview, .defaultMail:
      model.mailErrorMessage ?? model.errorMessage
    case .discovery, .browserReview, .defaultBrowser, .none:
      model.errorMessage
    }
  }

  private func applicationIcon(_ application: RoutedApplication) -> some View {
    Image(nsImage: NSWorkspace.shared.icon(forFile: application.applicationURL.path))
      .resizable()
      .scaledToFit()
      .frame(width: 24, height: 24)
      .accessibilityHidden(true)
  }

  private func rescan() {
    try? model.userRequestedRescan()
    profileAccessPresenter.requestIfPending(model: model)
  }
}

enum WelcomeStep: Equatable {
  case discovery
  case browserReview
  case defaultBrowser
  case mailReview
  case defaultMail
}

func welcomeStep(for onboardingStep: Int) -> WelcomeStep? {
  switch onboardingStep {
  case 1: .discovery
  case 2: .browserReview
  case 3: .defaultBrowser
  case 4: .mailReview
  case 5: .defaultMail
  default: nil
  }
}

@MainActor
func advanceOnboardingAndPresentProfileAccess(
  model: AppModel,
  profileAccessPresenter: any ProfileAccessPresenting
) {
  let previousStep = model.onboardingStep
  model.advanceOnboarding()
  if previousStep == 2, model.onboardingStep == 3 {
    profileAccessPresenter.requestIfPending(model: model)
  }
}

@MainActor
struct WelcomeLifecycle {
  let dismiss: @MainActor () -> Void

  func shouldShowContent(isOnboardingComplete: Bool) -> Bool {
    !isOnboardingComplete
  }

  func synchronize(isOnboardingComplete: Bool) {
    if isOnboardingComplete {
      dismiss()
    }
  }
}

struct BrowserDefaultStatusRows: View {
  @AppStorage(L10n.preferenceKey) private var localizationSelection = L10n.system
  let status: DefaultHandlerStatus

  var body: some View {
    let _ = localizationSelection
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
      DefaultStatusRow(scheme: "HTTP", status: status.http)
      DefaultStatusRow(scheme: "HTTPS", status: status.https)
    }
  }
}

struct DefaultStatusRow: View {
  @AppStorage(L10n.preferenceKey) private var localizationSelection = L10n.system
  let scheme: String
  let status: SchemeStatus

  var body: some View {
    let _ = localizationSelection
    GridRow {
      Text(scheme).fontWeight(.medium)
      Label(
        statusDescription,
        systemImage: status == .isDefault ? "checkmark.circle.fill" : "exclamationmark.circle"
      )
      .foregroundStyle(status == .isDefault ? .green : .secondary)
    }
  }

  private var statusDescription: String {
    switch status {
    case .isDefault: "PickVia"
    case .notDefault: L10n.tr("Another app")
    case .unknown: L10n.tr("Unknown")
    }
  }
}
