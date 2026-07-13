import AppKit
import PickViaCore

@MainActor
public protocol ProfileAccessFolderSelecting: AnyObject {
  func selectRoot(for descriptor: BrowserDescriptor) async -> URL?
}

@MainActor
protocol ProfileAccessOpenPanelDriving: AnyObject {
  var prompt: String { get set }
  var message: String { get set }
  var canChooseDirectories: Bool { get set }
  var canChooseFiles: Bool { get set }
  var allowsMultipleSelection: Bool { get set }
  var directoryURL: URL? { get set }
  func begin() async -> URL?
}

@MainActor
public final class ProfileAccessFolderSelector: ProfileAccessFolderSelecting {
  private let makePanel: @MainActor () -> any ProfileAccessOpenPanelDriving
  private let homeDirectory: URL

  init(
    makePanel: @escaping @MainActor () -> any ProfileAccessOpenPanelDriving = {
      AppKitProfileAccessOpenPanelDriver()
    },
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.makePanel = makePanel
    self.homeDirectory = homeDirectory
  }

  public func selectRoot(for descriptor: BrowserDescriptor) async -> URL? {
    let panel = makePanel()
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
    return await panel.begin()
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

  func begin() async -> URL? {
    await withCheckedContinuation { continuation in
      panel.begin { [panel] response in
        continuation.resume(
          returning: Self.selectedURL(for: response, panelURL: panel.url)
        )
      }
    }
  }

  static func selectedURL(
    for response: NSApplication.ModalResponse,
    panelURL: URL?
  ) -> URL? {
    response == .OK ? panelURL : nil
  }
}
