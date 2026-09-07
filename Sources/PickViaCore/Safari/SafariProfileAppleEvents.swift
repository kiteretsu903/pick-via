import AppKit
import ApplicationServices
import Foundation
import OSLog

/// All values use typed Apple Event descriptors; URLs never become executable script text.
/// An actor keeps synchronous IPC off the UI actor and serializes access to the target process.
actor SafariProfileAppleEvents {
  private let processIdentifier: Int32
  private let logger = Logger(subsystem: "dev.bozhenpeng.PickVia", category: "SafariProfiles")
  init(processIdentifier: Int32) { self.processIdentifier = processIdentifier }

  static func allWindowsOrdinal() throws -> NSAppleEventDescriptor {
    // Apple Event scalar descriptors use native byte order at the API boundary.
    var ordinal = UInt32(kAEAll)
    let allDescriptor = withUnsafeBytes(of: &ordinal) {
      NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal, data: Data($0))
    }
    guard let all = allDescriptor else { throw SafariProfileError.windowNotVerified }
    return all
  }

  func windowIDs() throws -> Set<Int32> {
    let all = try Self.allWindowsOrdinal()
    let windows = object(want: cWindow, form: OSType(formAbsolutePosition), selector: all)
    let ids = property(pID, of: windows)
    let result = try send(kAEGetData, object: ids)
    guard result.descriptorType == typeAEList else { throw SafariProfileError.windowNotVerified }
    if result.numberOfItems == 0 { return [] }
    let values = (1...result.numberOfItems).compactMap { result.atIndex($0)?.int32Value }
    guard values.allSatisfy({ $0 > 0 }), Set(values).count == values.count else {
      throw SafariProfileError.windowNotVerified
    }
    return Set(values)
  }

  func open(url: URL, windowID: Int32) throws {
    let window = object(want: cWindow, form: OSType(formUniqueID), selector: NSAppleEventDescriptor(int32: windowID))
    // Safari.sdef: current tab = cTab, URL = pURL.
    let tab = property(0x63546162, of: window)
    let urlProperty = property(0x7055524c, of: tab)
    _ = try send(kAESetData, object: urlProperty, data: NSAppleEventDescriptor(string: url.absoluteString))
  }

  private func property(_ code: OSType, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
    object(want: cProperty, form: OSType(formPropertyID),
      selector: NSAppleEventDescriptor(typeCode: code), container: container)
  }

  private func object(want: OSType, form: OSType, selector: NSAppleEventDescriptor,
    container: NSAppleEventDescriptor = NSAppleEventDescriptor.null()) -> NSAppleEventDescriptor {
    let descriptor = NSAppleEventDescriptor.record()
    descriptor.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: OSType(keyAEDesiredClass))
    descriptor.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: OSType(keyAEKeyForm))
    descriptor.setDescriptor(selector, forKeyword: OSType(keyAEKeyData))
    descriptor.setDescriptor(container, forKeyword: OSType(keyAEContainer))
    return descriptor.coerce(toDescriptorType: typeObjectSpecifier)!
  }

  private func send(_ eventID: OSType, object: NSAppleEventDescriptor,
    data: NSAppleEventDescriptor? = nil) throws -> NSAppleEventDescriptor {
    let address = NSAppleEventDescriptor(processIdentifier: processIdentifier)
    guard let addressDescriptor = address.aeDesc else { throw SafariProfileError.windowNotVerified }
    let permission = AEDeterminePermissionToAutomateTarget(addressDescriptor, typeWildCard, typeWildCard, false)
    logger.notice("Safari Automation permission status \(permission)")
    if permission == -1744 {
      let requested = AEDeterminePermissionToAutomateTarget(addressDescriptor, typeWildCard, typeWildCard, true)
      guard requested == noErr else { throw SafariProfileError.automationRequired }
    } else if permission != noErr {
      throw SafariProfileError.automationRequired
    }
    let event = NSAppleEventDescriptor.appleEvent(withEventClass: kAECoreSuite, eventID: eventID,
      targetDescriptor: NSAppleEventDescriptor(processIdentifier: processIdentifier),
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(object, forKeyword: keyDirectObject)
    if let data { event.setParam(data, forKeyword: keyAEData) }
    do {
      let reply = try event.sendEvent(options: [.waitForReply, .canInteract], timeout: 10)
      let error = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0
      guard error == 0 else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(error)) }
      return reply.paramDescriptor(forKeyword: keyAEResult) ?? NSAppleEventDescriptor.null()
    } catch {
      let code = (error as NSError).code
      logger.error("Direct Safari Apple Event failed with code \(code)")
      if code == -1743 || code == -1744 { throw SafariProfileError.automationRequired }
      throw SafariProfileError.windowNotVerified
    }
  }
}
