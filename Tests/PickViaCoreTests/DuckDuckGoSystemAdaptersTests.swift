import CoreServices
import Foundation
import Testing

@testable import PickViaCore

struct DuckDuckGoSystemAdaptersTests {
  @Test func reopenDescriptorUsesCoreReopenEvent() {
    let value = SystemDuckDuckGoAppleEventSender.descriptor(
      for: .reopen,
      processIdentifier: 123
    )
    let expectedTarget = NSAppleEventDescriptor(processIdentifier: 123)
    let actualTarget = value.attributeDescriptor(forKeyword: keyAddressAttr)

    #expect(value.eventClass == kCoreEventClass)
    #expect(value.eventID == kAEReopenApplication)
    #expect(actualTarget?.descriptorType == expectedTarget.descriptorType)
    #expect(actualTarget?.data == expectedTarget.data)
  }

  @Test func urlDescriptorUsesGURLAndExactDirectObject() {
    let url = URL(string: "https://example.com/exact?x=1")!
    let value = SystemDuckDuckGoAppleEventSender.descriptor(
      for: .openURL(url),
      processIdentifier: 456
    )

    #expect(value.eventClass == 0x4755_524C)
    #expect(value.eventID == 0x4755_524C)
    #expect(
      value.paramDescriptor(forKeyword: keyDirectObject)?.stringValue
        == url.absoluteString
    )
  }

  @Test func sendOptionsWaitButNeverPromptForConsent() {
    let raw = SystemDuckDuckGoAppleEventSender.sendOptions.rawValue
    let expected = UInt(kAEWaitReply | kAENeverInteract | kAEDoNotPromptForUserConsent)

    #expect(raw == expected)
    #expect(raw & UInt(kAEWaitReply) != 0)
    #expect(raw & UInt(kAENeverInteract) != 0)
    #expect(raw & UInt(kAEDoNotPromptForUserConsent) != 0)
    #expect(raw & UInt(kAECanInteract) == 0)
  }

  @MainActor @Test func launchConfigurationCopiesRequestAndDisablesUnsafeWorkspaceBehavior() {
    let request = DuckDuckGoApplicationLaunchRequest(
      applicationURL: URL(fileURLWithPath: "/Applications/DuckDuckGo.app"),
      urls: [],
      createsNewApplicationInstance: true,
      arguments: ["-ApplePersistenceIgnoreState", "YES"],
      environment: ["CFFIXED_USER_HOME": "/tmp/isolated"],
      activates: false
    )

    let value = SystemDuckDuckGoApplicationManager.configuration(for: request)

    #expect(value.createsNewApplicationInstance)
    #expect(!value.allowsRunningApplicationSubstitution)
    #expect(!value.promptsUserIfNeeded)
    #expect(!value.addsToRecentItems)
    #expect(!value.activates)
    #expect(value.arguments == request.arguments)
    #expect(value.environment == request.environment)
  }
}
