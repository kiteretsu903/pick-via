import Foundation
import PickViaCore

public enum ChooserShortcut: Equatable, Sendable {
  case number(Int)
  case letter(Character)

  private static let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

  public var label: String {
    switch self {
    case .number(let number): String(number)
    case .letter(let letter): String(letter)
    }
  }

  public static func forVisibleIndex(_ index: Int) -> ChooserShortcut? {
    guard index >= 0 else { return nil }
    if index < 9 {
      return .number(index + 1)
    }

    let letterIndex = index - 9
    guard letters.indices.contains(letterIndex) else { return nil }
    return .letter(letters[letterIndex])
  }

  public static func parse(_ character: Character?) -> ChooserShortcut? {
    guard let character, let asciiValue = character.asciiValue else { return nil }

    switch asciiValue {
    case 49...57:
      return .number(Int(asciiValue - 48))
    case 65...90:
      return .letter(character)
    case 97...122:
      let uppercase = UnicodeScalar(asciiValue - 32)
      return .letter(Character(String(uppercase)))
    default:
      return nil
    }
  }
}

public enum ChooserRow: Equatable, Identifiable, Sendable {
  case target(RouteTarget.ID, shortcut: ChooserShortcut?)

  public var id: RouteTarget.ID { targetID }

  public var targetID: RouteTarget.ID {
    switch self {
    case .target(let id, _): id
    }
  }

  public var shortcut: ChooserShortcut? {
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
  case shortcut(ChooserShortcut)
}

public enum ChooserAction: Equatable, Sendable {
  case select(RouteTarget.ID)
  case cancel
  case none
}

public struct ChooserPresentation: Equatable, Sendable {
  public let request: RoutingRequest
  public let groups: [ChooserGroup]
  public let rows: [ChooserRow]
  public let displayURL: String?
  public private(set) var selectedIndex: Int?
  public private(set) var errorMessage: String?

  private let applications: [RoutedApplication]
  private let targets: [RouteTarget]

  public var kind: RouteKind { request.kind }

  public var heading: String {
    request.kind == .mail ? "Open email with" : "Open link with"
  }

  public var showsCopyAction: Bool { request.kind == .web }

  public var emptyStateMessage: String {
    request.kind == .mail
      ? "No available mail applications. Open Mail Settings to enable or rescan one."
      : "No available browser targets. Open Browser Settings to add or enable one."
  }

  public static func make(
    request: RoutingRequest,
    applications: [RoutedApplication],
    targets: [RouteTarget],
    error: LaunchFailure? = nil,
    preservingSelection targetID: RouteTarget.ID? = nil
  ) -> ChooserPresentation {
    let availableApplications = applications.filter {
      $0.supports(request.kind) && $0.isAvailable(for: request.kind)
    }
    let applicationIDs = Set(availableApplications.map(\.id))
    let indexedTargets = targets.enumerated().filter { _, target in
      target.routeKind == request.kind
        && target.isEnabled
        && target.availability == .available
        && applicationIDs.contains(target.applicationID)
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
      let applicationTargets = sortedTargets.filter { $0.applicationID == application.id }
      guard !applicationTargets.isEmpty else { continue }
      assert(
        request.kind != .mail || applicationTargets.count == 1,
        "Mail targets must be presented as direct application rows."
      )

      let applicationRows = applicationTargets.map { target -> ChooserRow in
        let shortcut = ChooserShortcut.forVisibleIndex(shortcutIndex)
        shortcutIndex += 1
        let row = ChooserRow.target(target.id, shortcut: shortcut)
        rows.append(row)
        return row
      }

      if applicationRows.count == 1, let row = applicationRows.first {
        groups.append(.direct(browserID: application.id, row: row))
      } else {
        groups.append(.group(browserID: application.id, rows: applicationRows))
      }
    }

    let selectedIndex = targetID.flatMap { selectedID in
      rows.firstIndex { $0.targetID == selectedID }
    }

    return ChooserPresentation(
      request: request,
      groups: groups,
      rows: rows,
      displayURL: request.kind == .web ? sanitizedDisplayURL(request.url) : nil,
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

    guard let current = selectedIndex else {
      selectedIndex =
        switch direction {
        case .up: rows.count - 1
        case .down: 0
        }
      return
    }

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
    case .shortcut(let shortcut):
      guard let row = rows.first(where: { $0.shortcut == shortcut }) else { return .none }
      return .select(row.targetID)
    }
  }

  public mutating func setError(_ failure: LaunchFailure?) {
    errorMessage = failure?.message
  }

  public func application(for applicationID: RoutedApplication.ID) -> RoutedApplication? {
    applications.first { $0.id == applicationID }
  }

  public func target(for row: ChooserRow) -> RouteTarget? {
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
