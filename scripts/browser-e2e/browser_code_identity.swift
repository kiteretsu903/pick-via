import Foundation
import Security

private enum AttestationExit: Int32 {
  case usage = 64
  case identityMismatch = 70
}

private func canonicalPath(_ value: String) -> String {
  URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath().path
}

private func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
  var information: CFDictionary?
  guard
    SecCodeCopySigningInformation(
      code,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    ) == errSecSuccess,
    let information = information as? [String: Any]
  else {
    return nil
  }
  return information
}

private func attest(
  processIdentifier: Int32,
  expectedCodePath: String,
  expectedExecutablePath: String,
  expectedBundleIdentifier: String
) -> Bool {
  let attributes =
    [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)]
    as CFDictionary
  var guest: SecCode?
  guard
    SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess,
    let guest,
    SecCodeCheckValidity(guest, [], nil) == errSecSuccess
  else {
    return false
  }

  var runningStaticCode: SecStaticCode?
  var expectedStaticCode: SecStaticCode?
  var runningCodePath: CFURL?
  guard
    SecCodeCopyStaticCode(guest, [], &runningStaticCode) == errSecSuccess,
    let runningStaticCode,
    SecStaticCodeCheckValidity(runningStaticCode, [], nil) == errSecSuccess,
    SecCodeCopyPath(runningStaticCode, [], &runningCodePath) == errSecSuccess,
    let runningCodePath,
    canonicalPath((runningCodePath as URL).path) == canonicalPath(expectedCodePath),
    SecStaticCodeCreateWithPath(
      URL(fileURLWithPath: expectedCodePath) as CFURL,
      [],
      &expectedStaticCode
    ) == errSecSuccess,
    let expectedStaticCode,
    SecStaticCodeCheckValidity(expectedStaticCode, [], nil) == errSecSuccess,
    let runningInformation = signingInformation(runningStaticCode),
    let expectedInformation = signingInformation(expectedStaticCode),
    let runningIdentifier =
      runningInformation[kSecCodeInfoIdentifier as String] as? String,
    let expectedIdentifier =
      expectedInformation[kSecCodeInfoIdentifier as String] as? String,
    runningIdentifier == expectedBundleIdentifier,
    expectedIdentifier == expectedBundleIdentifier,
    let runningHash = runningInformation[kSecCodeInfoUnique as String] as? Data,
    let expectedHash = expectedInformation[kSecCodeInfoUnique as String] as? Data,
    runningHash == expectedHash,
    let runningExecutable =
      runningInformation[kSecCodeInfoMainExecutable as String] as? URL,
    let expectedExecutable =
      expectedInformation[kSecCodeInfoMainExecutable as String] as? URL,
    canonicalPath(runningExecutable.path) == canonicalPath(expectedExecutablePath),
    canonicalPath(expectedExecutable.path) == canonicalPath(expectedExecutablePath)
  else {
    return false
  }
  return true
}

guard
  CommandLine.arguments.count == 5,
  let processIdentifier = Int32(CommandLine.arguments[1]),
  processIdentifier > 0
else {
  exit(AttestationExit.usage.rawValue)
}

guard
  attest(
    processIdentifier: processIdentifier,
    expectedCodePath: CommandLine.arguments[2],
    expectedExecutablePath: CommandLine.arguments[3],
    expectedBundleIdentifier: CommandLine.arguments[4]
  )
else {
  exit(AttestationExit.identityMismatch.rawValue)
}

FileHandle.standardOutput.write(Data("OK\n".utf8))
