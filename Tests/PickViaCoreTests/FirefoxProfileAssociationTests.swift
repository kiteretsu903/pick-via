import Foundation
import Testing

@testable import PickViaCore

struct FirefoxProfileAssociationTests {
  @Test func readsRecordedApplicationWithoutGuessingProfileNames() {
    let data = Data(
      "[Compatibility]\nLastPlatformDir=/Applications/Renamed Firefox.app/Contents/Resources\n".utf8
    )
    #expect(
      FirefoxProfileAssociation.applicationURL(data: data)?.path
        == "/Applications/Renamed Firefox.app")
  }

  @Test(arguments: [
    "", "[Other]\nLastPlatformDir=/Applications/Firefox.app/Contents/Resources",
    "[Compatibility]\nLastPlatformDir=relative.app/Contents/Resources",
    "[Compatibility]\nLastPlatformDir=/tmp/unrecognized",
    "[Compatibility]\nLastPlatformDir=/Applications/Firefox.app/Contents/Resources\nLastPlatformDir=/Applications/Nightly.app/Contents/Resources",
  ])
  func unknownOrAmbiguousMetadataDoesNotAssignAnEdition(_ text: String) {
    #expect(FirefoxProfileAssociation.applicationURL(data: Data(text.utf8)) == nil)
  }
}
