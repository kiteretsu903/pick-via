import SwiftUI

public struct WelcomeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.profileAccessPresenter) private var profileAccessPresenter
  @Environment(\.dismissWindow) private var dismissWindow

  public init() {}

  public var body: some View {
    Group {
      if lifecycle.shouldShowContent(isOnboardingComplete: model.isOnboardingComplete) {
        welcomeContent
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
      Text("Welcome to PickVia")
        .font(.largeTitle.bold())

      switch model.onboardingStep {
      case 1:
        discoveryStep
      case 2:
        reviewStep
      case 3:
        defaultBrowserStep
      default:
        EmptyView()
      }

      if let errorMessage = model.errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      }
    }
    .padding(32)
    .frame(width: 560)
    .frame(minHeight: 360, alignment: .topLeading)
  }

  private var discoveryStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Discover browsers", systemImage: "sparkle.magnifyingglass")
        .font(.title2.bold())
      Text(
        "PickVia found \(model.browsers.filter(\.isAvailable).count) supported browsers on this Mac."
      )
      .foregroundStyle(.secondary)
      HStack {
        Button("Scan Again") { rescan() }
        Spacer()
        Button("Continue") { model.advanceOnboarding() }
          .buttonStyle(.borderedProminent)
      }
    }
  }

  private var reviewStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Review browser targets", systemImage: "checklist")
        .font(.title2.bold())
      Text("Choose which profiles and modes should appear when you open a link.")
        .foregroundStyle(.secondary)
      List(model.targets.sorted { $0.sortOrder < $1.sortOrder }) { target in
        HStack {
          Text(target.label)
          Spacer()
          Text(target.isEnabled ? "Enabled" : "Hidden")
            .foregroundStyle(.secondary)
        }
      }
      .frame(minHeight: 150)
      HStack {
        Button("Rescan") { rescan() }
        Spacer()
        Button("Continue") {
          advanceOnboardingAndPresentProfileAccess(
            model: model,
            profileAccessPresenter: profileAccessPresenter
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canRequestDefaultBrowser)
      }
    }
  }

  private var defaultBrowserStep: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Make PickVia your default browser", systemImage: "checkmark.seal")
        .font(.title2.bold())
      Text("macOS asks separately for permission to handle HTTP and HTTPS links.")
        .foregroundStyle(.secondary)
      DefaultStatusRows(status: model.defaultStatus)
      HStack {
        Spacer()
        Button("Set as Default") {
          Task { await model.requestDefaultBrowser() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canRequestDefaultBrowser)
      }
    }
  }

  private func rescan() {
    try? model.userRequestedRescan()
    profileAccessPresenter.requestIfPending(model: model)
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

struct DefaultStatusRows: View {
  let status: DefaultBrowserStatus

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
      statusRow("HTTP", status.http)
      statusRow("HTTPS", status.https)
    }
  }

  private func statusRow(_ scheme: String, _ status: SchemeStatus) -> some View {
    GridRow {
      Text(scheme).fontWeight(.medium)
      Label(
        statusText(status),
        systemImage: status == .isDefault ? "checkmark.circle.fill" : "exclamationmark.circle"
      )
      .foregroundStyle(status == .isDefault ? .green : .secondary)
    }
  }

  private func statusText(_ status: SchemeStatus) -> String {
    switch status {
    case .isDefault: "PickVia"
    case .notDefault: "Another app"
    case .unknown: "Unknown"
    }
  }
}
