#if PICKVIA_E2E_AUTOMATION
  import Foundation
  import PickViaCore

  @MainActor
  final class E2EChooserPresenter: ChooserPresenting {
    private let base: any ChooserPresenting
    private let control: E2EControl?
    private let profileGrant: E2EValidatedProfileGrant?
    private let statusWriter: any E2EStatusWriting
    private var handledRequestIDs: Set<UUID> = []
    private var reportedLaunchErrorRequestIDs: Set<UUID> = []

    init(
      base: any ChooserPresenting,
      control: E2EControl?,
      profileGrant: E2EValidatedProfileGrant? = nil,
      statusWriter: any E2EStatusWriting
    ) {
      self.base = base
      self.control = control
      self.profileGrant = profileGrant
      self.statusWriter = statusWriter
    }

    func present(
      request: RoutingRequest,
      applications: [RoutedApplication],
      targets: [RouteTarget],
      error: LaunchFailure?,
      onSelection: @escaping (RouteTarget.ID) -> Void,
      onCancel: @escaping () -> Void
    ) {
      base.present(
        request: request,
        applications: applications,
        targets: targets,
        error: error,
        onSelection: { _ in },
        onCancel: {}
      )

      if error != nil {
        handledRequestIDs.insert(request.id)
        if reportedLaunchErrorRequestIDs.insert(request.id).inserted {
          report(.launchError)
        }
        base.dismiss()
        return
      }

      guard handledRequestIDs.insert(request.id).inserted else {
        base.dismiss()
        return
      }
      guard let control else {
        base.dismiss()
        return
      }

      switch E2ETargetDecision.evaluate(
        control: control,
        requestKind: request.kind,
        applications: applications,
        targets: targets,
        profileGrant: profileGrant
      ) {
      case .select(let targetID):
        guard
          statusWriter.write(
            .selected,
            sessionNonce: control.sessionNonce,
            to: control.statusFIFO
          )
        else {
          base.dismiss()
          return
        }
        Task { @MainActor in
          onSelection(targetID)
        }
      case .reject(let outcome):
        report(outcome)
        base.dismiss()
      }
    }

    func dismiss() {
      base.dismiss()
    }

    private func report(_ outcome: E2ESelectionOutcome) {
      guard let control else { return }
      _ = statusWriter.write(
        outcome,
        sessionNonce: control.sessionNonce,
        to: control.statusFIFO
      )
    }
  }
#endif
