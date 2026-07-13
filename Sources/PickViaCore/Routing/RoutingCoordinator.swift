import Foundation

public struct RoutingRequest: Equatable, Sendable {
    public let id: UUID
    public let url: URL

    public init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }
}

public struct RoutingTargetSnapshot: Equatable, Sendable {
    public let applications: [BrowserApplication]
    public let targets: [BrowserTarget]

    public init(applications: [BrowserApplication], targets: [BrowserTarget]) {
        self.applications = applications
        self.targets = targets
    }
}

public struct LaunchFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public protocol TargetProviding: Sendable {
    func availableSnapshot() -> RoutingTargetSnapshot
}

@MainActor
public protocol ChooserPresenting: AnyObject {
    func present(
        request: RoutingRequest,
        applications: [BrowserApplication],
        targets: [BrowserTarget],
        error: LaunchFailure?,
        onSelection: @escaping (BrowserTarget.ID) -> Void,
        onCancel: @escaping () -> Void
    )

    func dismiss()
}

public protocol BrowserLaunching: Sendable {
    func launch(
        url: URL,
        application: BrowserApplication,
        target: BrowserTarget
    ) async throws
}

@MainActor
public final class RoutingCoordinator {
    public private(set) var currentRequest: RoutingRequest?
    public private(set) var currentError: LaunchFailure?

    private static let sanitizedLaunchFailure = LaunchFailure(
        message: "Could not open the selected browser target."
    )

    private let targetProvider: any TargetProviding
    private let chooser: any ChooserPresenting
    private let launcher: any BrowserLaunching
    private var queue: [RoutingRequest] = []
    private var currentSnapshot: RoutingTargetSnapshot?

    public init(
        targetProvider: any TargetProviding,
        chooser: any ChooserPresenting,
        launcher: any BrowserLaunching
    ) {
        self.targetProvider = targetProvider
        self.chooser = chooser
        self.launcher = launcher
    }

    public func enqueue(_ url: URL) {
        queue.append(RoutingRequest(url: url))

        if currentRequest == nil {
            advanceToNextRequest()
        }
    }

    public func selected(targetID: BrowserTarget.ID) async {
        guard
            let request = currentRequest,
            let snapshot = currentSnapshot,
            let target = snapshot.targets.first(where: { $0.id == targetID }),
            let application = snapshot.applications.first(where: { $0.id == target.browserID })
        else {
            launchFailed(Self.sanitizedLaunchFailure)
            return
        }

        do {
            try await launcher.launch(
                url: request.url,
                application: application,
                target: target
            )
        } catch {
            guard currentRequest?.id == request.id else { return }
            launchFailed(Self.sanitizedLaunchFailure)
            return
        }

        guard currentRequest?.id == request.id else { return }
        finishCurrentRequest()
    }

    public func cancelCurrent() {
        guard currentRequest != nil else { return }
        finishCurrentRequest()
    }

    public func launchFailed(_ failure: LaunchFailure) {
        guard let request = currentRequest, let snapshot = currentSnapshot else { return }
        currentError = failure
        present(request: request, snapshot: snapshot, error: failure)
    }

    private func finishCurrentRequest() {
        chooser.dismiss()
        queue.removeFirst()
        currentRequest = nil
        currentError = nil
        currentSnapshot = nil
        advanceToNextRequest()
    }

    private func advanceToNextRequest() {
        guard let request = queue.first else { return }
        let snapshot = targetProvider.availableSnapshot()
        currentRequest = request
        currentSnapshot = snapshot
        present(request: request, snapshot: snapshot, error: nil)
    }

    private func present(
        request: RoutingRequest,
        snapshot: RoutingTargetSnapshot,
        error: LaunchFailure?
    ) {
        chooser.present(
            request: request,
            applications: snapshot.applications,
            targets: snapshot.targets,
            error: error,
            onSelection: { [weak self] targetID in
                Task { @MainActor in
                    await self?.selected(targetID: targetID)
                }
            },
            onCancel: { [weak self] in
                self?.cancelCurrent()
            }
        )
    }
}
