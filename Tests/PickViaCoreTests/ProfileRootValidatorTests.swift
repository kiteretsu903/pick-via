import Foundation
import Testing

@testable import PickViaCore

struct ProfileRootValidatorTests {
  @Test func chromiumRootRequiresReadableLocalState() throws {
    let root = URL(fileURLWithPath: "/Chrome", isDirectory: true)
    let validator = BrowserProfileRootValidator(
      fileSystem: ValidatorFileSystem(files: [
        root.appending(path: "Local State"): Data("{}".utf8)
      ]))

    #expect(
      validator.validate(root, for: try #require(browserDescriptor("com.google.Chrome")))
        == .valid(marker: "Local State"))
    #expect(
      validator.validate(root, for: try #require(browserDescriptor("org.mozilla.firefox")))
        == .invalid(requiredMarker: "profiles.ini"))
  }

  @Test func firefoxRootRequiresReadableProfilesINI() throws {
    let root = URL(fileURLWithPath: "/Firefox", isDirectory: true)
    let validator = BrowserProfileRootValidator(
      fileSystem: ValidatorFileSystem(files: [
        root.appending(path: "profiles.ini"): Data("[Profile0]".utf8)
      ]))

    #expect(
      validator.validate(root, for: try #require(browserDescriptor("org.mozilla.firefox")))
        == .valid(marker: "profiles.ini"))
    #expect(
      validator.validate(root, for: try #require(browserDescriptor("com.google.Chrome")))
        == .invalid(requiredMarker: "Local State"))
  }

  @Test func permissionDeniedMarkerIsUnreadable() throws {
    let root = URL(fileURLWithPath: "/Chrome", isDirectory: true)
    let marker = root.appending(path: "Local State")
    let descriptor = try #require(browserDescriptor("com.google.Chrome"))
    let errors: [any Error] = [
      CocoaError(.fileReadNoPermission),
      POSIXError(.EACCES),
      POSIXError(.EPERM),
    ]

    for error in errors {
      let validator = BrowserProfileRootValidator(
        fileSystem: ValidatorFileSystem(readErrors: [marker: error]))
      #expect(validator.validate(root, for: descriptor) == .unreadable)
    }
  }

  @Test func missingMarkerIsInvalid() throws {
    let root = URL(fileURLWithPath: "/Chrome", isDirectory: true)
    let marker = root.appending(path: "Local State")
    let descriptor = try #require(browserDescriptor("com.google.Chrome"))
    let errors: [any Error] = [
      CocoaError(.fileNoSuchFile),
      CocoaError(.fileReadNoSuchFile),
      POSIXError(.ENOENT),
    ]

    for error in errors {
      let validator = BrowserProfileRootValidator(
        fileSystem: ValidatorFileSystem(readErrors: [marker: error]))
      #expect(
        validator.validate(root, for: descriptor)
          == .invalid(requiredMarker: "Local State"))
    }
  }

  @Test func supportedFamiliesDeclareOnlyTheirApprovedMarkers() {
    #expect(BrowserProfileRootValidator.requiredMarker(for: .chromium) == "Local State")
    #expect(BrowserProfileRootValidator.requiredMarker(for: .firefox) == "profiles.ini")
    #expect(BrowserProfileRootValidator.requiredMarker(for: .safari) == nil)
  }
}

private func browserDescriptor(_ bundleIdentifier: String) -> BrowserDescriptor? {
  BrowserDescriptor.supported.first { $0.bundleIdentifier == bundleIdentifier }
}

private final class ValidatorFileSystem: FileSystem, @unchecked Sendable {
  private let files: [URL: Data]
  private let readErrors: [URL: any Error]

  init(files: [URL: Data] = [:], readErrors: [URL: any Error] = [:]) {
    self.files = files
    self.readErrors = readErrors
  }

  func read(from url: URL) throws -> Data {
    if let error = readErrors[url] { throw error }
    guard let data = files[url] else { throw CocoaError(.fileNoSuchFile) }
    return data
  }

  func fileExists(at url: URL) -> Bool { false }
  func createDirectory(at url: URL) throws {}
  func writeAtomically(_ data: Data, to url: URL) throws {}
  func moveItem(at source: URL, to destination: URL) throws {}
  func replaceItem(at destination: URL, with source: URL) throws {}
}
