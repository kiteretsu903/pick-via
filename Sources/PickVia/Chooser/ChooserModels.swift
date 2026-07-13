import Foundation
import PickViaCore

public enum ChooserRow: Equatable, Identifiable, Sendable {
  case target(BrowserTarget.ID, shortcut: String?)

  public var id: BrowserTarget.ID { targetID }

  public var targetID: BrowserTarget.ID {
    switch self {
    case .target(let id, _): id
    }
  }

  public var shortcut: String? {
    switch self {
    case .target(_, let shortcut): shortcut
    }
  }
}

public enum ChooserGroup: Equatable, Identifiable, Sendable {
  case direct(browserID: BrowserApplication.ID, row: ChooserRow)
  case group(browserID: BrowserApplication.ID, rows: [ChooserRow])

  public var id: BrowserApplication.ID { browserID }

  public var browserID: BrowserApplication.ID {
    switch self {
    case .direct(let browserID, _), .group(let browserID, _): browserID
    }
  }

  public var rows: [ChooserRow] {
    switch self {
    case .direct(_, let row): [row]
    case .group(_, let rows): rows
    }
  }
}

public enum ChooserSelectionDirection: Sendable {
  case up
  case down
}

public enum ChooserKey: Equatable, Sendable {
  case up
  case down
  case returnKey
  case escape
  case number(Int)
}

public enum ChooserAction: Equatable, Sendable {
  case select(BrowserTarget.ID)
  case cancel
  case none
}

public struct ChooserPresentation: Equatable, Sendable {
  public let request: RoutingRequest
  public let groups: [ChooserGroup]
  public let rows: [ChooserRow]
  public let displayURL: String
  public private(set) var selectedIndex: Int?
  public private(set) var errorMessage: String?

  private let applications: [BrowserApplication]
  private let targets: [BrowserTarget]

  public static func make(
    request: RoutingRequest,
    applications: [BrowserApplication],
    targets: [BrowserTarget],
    error: LaunchFailure? = nil,
    preservingSelection targetID: BrowserTarget.ID? = nil
  ) -> ChooserPresentation {
    let availableApplications = applications.filter(\.isAvailable)
    let applicationIDs = Set(availableApplications.map(\.id))
    let indexedTargets = targets.enumerated().filter { _, target in
      target.isEnabled
        && target.availability == .available
        && applicationIDs.contains(target.browserID)
    }

    let sortedTargets = indexedTargets.sorted { left, right in
      if left.element.sortOrder == right.element.sortOrder {
        return left.offset < right.offset
      }
      return left.element.sortOrder < right.element.sortOrder
    }.map(\.element)

    var shortcutIndex = 0
    var groups: [ChooserGroup] = []
    var rows: [ChooserRow] = []

    for application in availableApplications {
      let browserTargets = sortedTargets.filter { $0.browserID == application.id }
      guard !browserTargets.isEmpty else { continue }

      let browserRows = browserTargets.map { target -> ChooserRow in
        shortcutIndex += 1
        let shortcut = shortcutIndex <= 9 ? String(shortcutIndex) : nil
        let row = ChooserRow.target(target.id, shortcut: shortcut)
        rows.append(row)
        return row
      }

      if browserRows.count == 1, let row = browserRows.first {
        groups.append(.direct(browserID: application.id, row: row))
      } else {
        groups.append(.group(browserID: application.id, rows: browserRows))
      }
    }

    let selectedIndex =
      targetID.flatMap { selectedID in
        rows.firstIndex { $0.targetID == selectedID }
      } ?? (rows.isEmpty ? nil : 0)

    return ChooserPresentation(
      request: request,
      groups: groups,
      rows: rows,
      displayURL: sanitizedDisplayURL(request.url),
      selectedIndex: selectedIndex,
      errorMessage: error?.message,
      applications: availableApplications,
      targets: sortedTargets
    )
  }

  public mutating func moveSelection(_ direction: ChooserSelectionDirection) {
    guard !rows.isEmpty else {
      selectedIndex = nil
      return
    }

    let current = selectedIndex ?? 0
    switch direction {
    case .up:
      selectedIndex = (current - 1 + rows.count) % rows.count
    case .down:
      selectedIndex = (current + 1) % rows.count
    }
  }

  public func handle(_ key: ChooserKey) -> ChooserAction {
    switch key {
    case .up, .down:
      return .none
    case .returnKey:
      guard let selectedIndex, rows.indices.contains(selectedIndex) else { return .none }
      return .select(rows[selectedIndex].targetID)
    case .escape:
      return .cancel
    case .number(let number):
      guard (1...9).contains(number) else { return .none }
      guard let row = rows.first(where: { $0.shortcut == String(number) }) else { return .none }
      return .select(row.targetID)
    }
  }

  public mutating func setError(_ failure: LaunchFailure?) {
    errorMessage = failure?.message
  }

  public func application(for browserID: BrowserApplication.ID) -> BrowserApplication? {
    applications.first { $0.id == browserID }
  }

  public func target(for row: ChooserRow) -> BrowserTarget? {
    targets.first { $0.id == row.targetID }
  }

  private static func sanitizedDisplayURL(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return "Web link"
    }
    components.user = nil
    components.password = nil
    return components.string ?? "Web link"
  }
}
