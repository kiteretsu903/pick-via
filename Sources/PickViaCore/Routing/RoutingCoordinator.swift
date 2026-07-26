import Foundation

public struct RoutingRequest: Equatable, Sendable {
  public let id: UUID
  public let kind: RouteKind
  public let url: URL

  public init(id: UUID = UUID(), kind: RouteKind, url: URL) {
    self.id = id
    self.kind = kind
    self.url = url
  }
}

public struct RoutingTargetSnapshot: Equatable, Sendable {
  public let applications: [RoutedApplication]
  public let targets: [RouteTarget]

  public init(applications: [RoutedApplication], targets: [RouteTarget]) {
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
  func availableSnapshot(for kind: RouteKind) -> RoutingTargetSnapshot
}

public final class MutableTargetSnapshot: TargetProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var config: PickViaConfig = .initial

  public init() {}

  public func publish(_ config: PickViaConfig) {
    lock.withLock { self.config = config }
  }

  public func availableSnapshot(for kind: RouteKind) -> RoutingTargetSnapshot {
    lock.withLock {
      let applications = config.applications.filter { $0.isAvailable(for: kind) }
      let applicationIDs = Set(applications.map(\.id))
      let targets = config.targets
        .filter {
          $0.routeKind == kind
            && $0.isEnabled
            && $0.availability == .available
            && applicationIDs.contains($0.applicationID)
        }
        .sorted {
          if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
          return $0.id < $1.id
        }
      let targetBrowserIDs = Set(targets.map(\.applicationID))
      return RoutingTargetSnapshot(
        applications: applications.filter { targetBrowserIDs.contains($0.id) },
        targets: targets
      )
    }
  }
}

@MainActor
public protocol ChooserPresenting: AnyObject {
  func present(
    request: RoutingRequest,
    applications: [RoutedApplication],
    targets: [RouteTarget],
    error: LaunchFailure?,
    onSelection: @escaping (RouteTarget.ID) -> Void,
    onCancel: @escaping () -> Void
  )

  func dismiss()
}

public protocol RouteLaunching: Sendable {
  func launch(
    url: URL,
    application: RoutedApplication,
    target: RouteTarget
  ) async throws
}

@MainActor
public final class RoutingCoordinator {
  public private(set) var currentRequest: RoutingRequest?
  public private(set) var currentError: LaunchFailure?

  private let targetProvider: any TargetProviding
  private let chooser: any ChooserPresenting
  private let launcher: any RouteLaunching
  private var queue: [RoutingRequest] = []
  private var currentSnapshot: RoutingTargetSnapshot?
  private var launchingRequestID: UUID?

  public init(
    targetProvider: any TargetProviding,
    chooser: any ChooserPresenting,
    launcher: any RouteLaunching
  ) {
    self.targetProvider = targetProvider
    self.chooser = chooser
    self.launcher = launcher
  }

  public func enqueue(_ url: URL) {
    guard let validated = try? URLValidator.validate(url) else { return }
    queue.append(RoutingRequest(kind: validated.kind, url: validated.url))

    if currentRequest == nil {
      advanceToNextRequest()
    }
  }

  public func selected(targetID: RouteTarget.ID) async {
    guard launchingRequestID == nil else { return }
    guard
      let request = currentRequest,
      let snapshot = currentSnapshot,
      let target = snapshot.targets.first(where: { $0.id == targetID }),
      target.routeKind == request.kind,
      let application = snapshot.applications.first(where: {
        $0.id == target.applicationID && $0.isAvailable(for: request.kind)
      })
    else {
      launchFailed(Self.sanitizedLaunchFailure(for: currentRequest?.kind ?? .web))
      return
    }

    launchingRequestID = request.id
    do {
      try await launcher.launch(
        url: request.url,
        application: application,
        target: target
      )
    } catch {
      guard
        currentRequest?.id == request.id,
        launchingRequestID == request.id
      else { return }
      launchFailed(Self.sanitizedLaunchFailure(for: request.kind))
      return
    }

    guard
      currentRequest?.id == request.id,
      launchingRequestID == request.id
    else { return }
    launchingRequestID = nil
    finishCurrentRequest()
  }

  public func cancelCurrent() {
    guard currentRequest != nil, launchingRequestID == nil else { return }
    finishCurrentRequest()
  }

  public func refreshCurrentPresentation() {
    guard let request = currentRequest, launchingRequestID == nil else { return }
    let snapshot = targetProvider.availableSnapshot(for: request.kind)
    currentSnapshot = snapshot
    present(request: request, snapshot: snapshot, error: currentError)
  }

  public func launchFailed(_ failure: LaunchFailure) {
    guard let request = currentRequest, let snapshot = currentSnapshot else { return }
    launchingRequestID = nil
    let sanitizedFailure = Self.sanitizedLaunchFailure(for: request.kind)
    currentError = sanitizedFailure
    present(request: request, snapshot: snapshot, error: sanitizedFailure)
  }

  private func finishCurrentRequest() {
    chooser.dismiss()
    queue.removeFirst()
    currentRequest = nil
    currentError = nil
    currentSnapshot = nil
    launchingRequestID = nil
    advanceToNextRequest()
  }

  private func advanceToNextRequest() {
    guard let request = queue.first else { return }
    let snapshot = targetProvider.availableSnapshot(for: request.kind)
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

  private static func sanitizedLaunchFailure(for kind: RouteKind) -> LaunchFailure {
    LaunchFailure(
      message: kind == .mail
        ? "Could not open the selected mail app."
        : "Could not open the selected browser target."
    )
  }
}
