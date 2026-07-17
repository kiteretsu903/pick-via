import AppKit
import Observation
import PickViaCore

@MainActor
public protocol ProfileAccessFolderSelecting: AnyObject {
  func selectRoot(for descriptor: BrowserDescriptor) async -> URL?
  func cancelSelection()
}

@MainActor
@Observable
final class ProfileAccessWizardSelectionCoordinator {
  private(set) var isSelectionInFlight = false

  @ObservationIgnored private let folderSelector: any ProfileAccessFolderSelecting
  @ObservationIgnored private var selectionTask: Task<Void, Never>?
  @ObservationIgnored private var presentationGeneration = 0
  @ObservationIgnored private var isPresentationActive = false

  init(folderSelector: any ProfileAccessFolderSelecting) {
    self.folderSelector = folderSelector
  }

  func beginPresentation() {
    guard !isPresentationActive else { return }
    presentationGeneration &+= 1
    isPresentationActive = true
  }

  @discardableResult
  func selectRoot(
    for descriptor: BrowserDescriptor,
    onSelection: @escaping @MainActor (URL) -> Void
  ) -> Bool {
    guard isPresentationActive, !isSelectionInFlight else { return false }
    isSelectionInFlight = true
    let generation = presentationGeneration
    selectionTask = Task { @MainActor [weak self, folderSelector] in
      guard
        let self,
        !Task.isCancelled,
        self.isPresentationActive,
        generation == self.presentationGeneration
      else {
        self?.selectionTask = nil
        self?.isSelectionInFlight = false
        return
      }
      let root = await folderSelector.selectRoot(for: descriptor)
      self.selectionTask = nil
      self.isSelectionInFlight = false
      guard
        !Task.isCancelled,
        self.isPresentationActive,
        generation == self.presentationGeneration,
        let root
      else { return }
      onSelection(root)
    }
    return true
  }

  func cancelOutstandingSelection() {
    guard isSelectionInFlight else { return }
    presentationGeneration &+= 1
    selectionTask?.cancel()
    folderSelector.cancelSelection()
  }

  func endPresentation() {
    isPresentationActive = false
    cancelOutstandingSelection()
  }

  func performSkip(_ action: @MainActor () -> Void) {
    endPresentation()
    action()
  }

  func performFinish(_ action: @MainActor () throws -> Void) rethrows {
    cancelOutstandingSelection()
    try action()
  }
}

@MainActor
protocol ProfileAccessOpenPanelDriving: AnyObject {
  var prompt: String { get set }
  var message: String { get set }
  var canChooseDirectories: Bool { get set }
  var canChooseFiles: Bool { get set }
  var allowsMultipleSelection: Bool { get set }
  var directoryURL: URL? { get set }
  func beginSheetModal(for ownerWindow: NSWindow?) async -> URL?
  func cancel()
}

@MainActor
public final class ProfileAccessFolderSelector: ProfileAccessFolderSelecting {
  private let makePanel: @MainActor () -> any ProfileAccessOpenPanelDriving
  private let homeDirectory: URL
  private let ownerWindow: @MainActor () -> NSWindow?
  private var activePanel: (any ProfileAccessOpenPanelDriving)?
  private var selectionGeneration = 0

  init(
    makePanel: @escaping @MainActor () -> any ProfileAccessOpenPanelDriving = {
      AppKitProfileAccessOpenPanelDriver()
    },
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    ownerWindow: @escaping @MainActor () -> NSWindow? = { NSApplication.shared.keyWindow }
  ) {
    self.makePanel = makePanel
    self.homeDirectory = homeDirectory
    self.ownerWindow = ownerWindow
  }

  public func selectRoot(for descriptor: BrowserDescriptor) async -> URL? {
    guard !Task.isCancelled, activePanel == nil else { return nil }
    let panel = makePanel()
    activePanel = panel
    defer { activePanel = nil }
    let generation = selectionGeneration
    panel.prompt = "Grant Access"
    let marker =
      BrowserProfileRootValidator.requiredMarker(for: descriptor.family)
      ?? "profile metadata"
    panel.message = "Select the \(descriptor.displayName) data folder containing \(marker)."
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if let relativeRoot = descriptor.profileRoot {
      panel.directoryURL = homeDirectory.appending(path: relativeRoot)
    }
    let selectedRoot = await panel.beginSheetModal(for: ownerWindow())
    guard generation == selectionGeneration else { return nil }
    return selectedRoot
  }

  public func cancelSelection() {
    selectionGeneration &+= 1
    activePanel?.cancel()
  }
}

@MainActor
final class AppKitProfileAccessOpenPanelDriver: ProfileAccessOpenPanelDriving {
  private let panel: NSOpenPanel

  init(panel: NSOpenPanel = NSOpenPanel()) {
    self.panel = panel
  }

  var prompt: String {
    get { panel.prompt ?? "" }
    set { panel.prompt = newValue }
  }

  var message: String {
    get { panel.message }
    set { panel.message = newValue }
  }

  var canChooseDirectories: Bool {
    get { panel.canChooseDirectories }
    set { panel.canChooseDirectories = newValue }
  }

  var canChooseFiles: Bool {
    get { panel.canChooseFiles }
    set { panel.canChooseFiles = newValue }
  }

  var allowsMultipleSelection: Bool {
    get { panel.allowsMultipleSelection }
    set { panel.allowsMultipleSelection = newValue }
  }

  var directoryURL: URL? {
    get { panel.directoryURL }
    set { panel.directoryURL = newValue }
  }

  func beginSheetModal(for ownerWindow: NSWindow?) async -> URL? {
    guard let ownerWindow else { return nil }
    return await withCheckedContinuation { continuation in
      panel.beginSheetModal(for: ownerWindow) { [panel] response in
        continuation.resume(
          returning: Self.selectedURL(for: response, panelURL: panel.url)
        )
      }
    }
  }

  func cancel() {
    if let sheetParent = panel.sheetParent {
      sheetParent.endSheet(panel, returnCode: .cancel)
    } else {
      panel.cancel(nil)
    }
    panel.orderOut(nil)
  }

  static func selectedURL(
    for response: NSApplication.ModalResponse,
    panelURL: URL?
  ) -> URL? {
    response == .OK ? panelURL : nil
  }
}
