#!/usr/bin/env swift
import AppKit
import Darwin
import Foundation

private let maximumInputBytes = 4_096

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(EXIT_FAILURE)
}

private func readBoundedInput() -> Data {
  var input = Data()
  do {
    while input.count <= maximumInputBytes {
      let remainingProbeBytes = maximumInputBytes + 1 - input.count
      let chunk =
        try FileHandle.standardInput.read(
          upToCount: min(1_024, remainingProbeBytes)
        ) ?? Data()
      if chunk.isEmpty { return input }
      input.append(chunk)
    }
  } catch {
    fail("invalid input")
  }
  fail("invalid input")
}

guard CommandLine.arguments.count == 2 else {
  fail("invalid arguments")
}

let rawApplicationPath = CommandLine.arguments[1]
let lexicalApplicationURL = URL(fileURLWithPath: rawApplicationPath, isDirectory: true)
guard
  rawApplicationPath.hasPrefix("/"),
  lexicalApplicationURL.path == rawApplicationPath,
  lexicalApplicationURL.pathExtension.lowercased() == "app"
else {
  fail("invalid application")
}

let input = readBoundedInput()
guard
  !input.isEmpty,
  input.count <= maximumInputBytes,
  let rawURL = String(data: input, encoding: .utf8),
  !rawURL.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
  let url = URL(string: rawURL),
  let scheme = url.scheme?.lowercased(),
  scheme == "http" || scheme == "https",
  url.host != nil
else {
  fail("invalid input")
}

do {
  let values = try lexicalApplicationURL.resourceValues(
    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
  )
  guard values.isDirectory == true, values.isSymbolicLink != true else {
    fail("invalid application")
  }
} catch {
  fail("invalid application")
}

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.addsToRecentItems = false
NSWorkspace.shared.open(
  [url],
  withApplicationAt: lexicalApplicationURL,
  configuration: configuration
) { _, error in
  exit(error == nil ? EXIT_SUCCESS : EXIT_FAILURE)
}
dispatchMain()
