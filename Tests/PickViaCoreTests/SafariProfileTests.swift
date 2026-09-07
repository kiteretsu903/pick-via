import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import PickViaCore

struct SafariProfileTests {
  @Test func windowOrdinalUsesNativeAppleEventEncoding() throws {
    let descriptor = try SafariProfileAppleEvents.allWindowsOrdinal()
    #expect(descriptor.descriptorType == typeAbsoluteOrdinal)
    #expect(descriptor.enumCodeValue == OSType(kAEAll))
  }

  @Test func permissionNameFollowsMacOSVersion() {
    #expect(MacOSControlPermission.name(majorVersion: 26) == "Accessibility")
    #expect(MacOSControlPermission.name(majorVersion: 27) == "Device Control and Data Access")
    #expect(MacOSControlPermission.name(majorVersion: 28) == "Device Control and Data Access")
  }

  @Test func preservesSimilarNamesAndUnicode() throws {
    let names = ["Personal", "Work", "Work 1", "Work 2", "研究 & 開発", "A&Icon=B"]
    let items = try SafariProfileMenuItem.unique(names.map { "New\($0)Window?isDefaultProfile=false" })
    #expect(items.map(\.name) == names)
    for item in items {
      #expect(item.matchesWindowProfile(identifier: "TabGroupPickerButton?Profile=\(item.name)&Icon=person.fill"))
      #expect(!item.matchesWindowProfile(identifier: "TabGroupPickerButton?Profile=\(item.name) 2&Icon=person.fill"))
    }
    #expect(!items[1].matchesWindowProfile(identifier: "TabGroupPickerButton?Profile=Work&Icon=Other&Icon=person.fill"))
  }

  @Test(arguments: ["NewPrivateWindow", "NewWindow", "NewWindow?isDefaultProfile=true", "NewWorkWindow?isDefaultProfile=maybe", "NewWorkWindow?isDefaultProfile=true?isDefaultProfile=false"])
  func rejectsUnrecognizedMenuActions(_ identifier: String) {
    #expect(SafariProfileMenuItem(identifier: identifier) == nil)
  }

  @Test func rejectsDuplicateOrEmptyMenus() {
    #expect(throws: SafariProfileError.self) { try SafariProfileMenuItem.unique([]) }
    #expect(throws: SafariProfileError.self) {
      try SafariProfileMenuItem.unique(["NewWorkWindow?isDefaultProfile=true", "NewWorkWindow?isDefaultProfile=false"])
    }
  }

  @Test func supportsOnlyNormalProfileRoutingAndNoFileGrant() throws {
    let descriptor = try #require(BrowserDescriptor.descriptor(forBundleIdentifier: "com.apple.Safari"))
    #expect(descriptor.supportsRoute(hasProfile: true, mode: .normal))
    #expect(!descriptor.supportsRoute(hasProfile: true, mode: .private))
    #expect(!BrowserRoutingCapabilities(descriptor: descriptor).hasFileBackedProfiles)
    #expect(descriptor.requiredProfileMarker == nil)
  }
}
