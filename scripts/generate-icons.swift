#!/usr/bin/env swift
import AppKit
import Foundation

enum IconGenerationError: Error {
  case bitmapAllocationFailed(Int)
  case pngEncodingFailed(Int)
  case invalidGeneratedAsset(String)
  case invalidSourceArtwork(String)
  case invalidArguments
}

struct IconRepresentation {
  let pixels: Int
  let icnsType: String
}

let iconRepresentations = [
  IconRepresentation(pixels: 16, icnsType: "icp4"),
  IconRepresentation(pixels: 32, icnsType: "icp5"),
  IconRepresentation(pixels: 64, icnsType: "icp6"),
  IconRepresentation(pixels: 128, icnsType: "ic07"),
  IconRepresentation(pixels: 256, icnsType: "ic08"),
  IconRepresentation(pixels: 512, icnsType: "ic09"),
  IconRepresentation(pixels: 1024, icnsType: "ic10"),
]

let applicationArtworkFilename = "PickViaArtwork.png"

func color(_ hexadecimal: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    red: CGFloat((hexadecimal >> 16) & 0xff) / 255,
    green: CGFloat((hexadecimal >> 8) & 0xff) / 255,
    blue: CGFloat(hexadecimal & 0xff) / 255,
    alpha: alpha
  )
}

func bitmap(size: Int, drawing: (CGContext) -> Void) throws -> NSBitmapImageRep {
  guard
    let representation = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: size,
      pixelsHigh: size,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: representation)?.cgContext
  else {
    throw IconGenerationError.bitmapAllocationFailed(size)
  }
  context.clear(CGRect(x: 0, y: 0, width: size, height: size))
  drawing(context)
  return representation
}

func pngData(_ representation: NSBitmapImageRep, size: Int) throws -> Data {
  guard let data = representation.representation(using: .png, properties: [:]) else {
    throw IconGenerationError.pngEncodingFailed(size)
  }
  return data
}

func loadApplicationArtwork(repositoryRoot: URL) throws -> CGImage {
  let artworkURL = repositoryRoot.appending(path: "Support/Icons/\(applicationArtworkFilename)")
  guard let data = try? Data(contentsOf: artworkURL),
    let representation = NSBitmapImageRep(data: data),
    representation.pixelsWide >= 1024,
    representation.pixelsHigh >= 1024,
    representation.hasAlpha,
    let artwork = representation.cgImage
  else {
    throw IconGenerationError.invalidSourceArtwork(applicationArtworkFilename)
  }
  return artwork
}

func drawApplicationIcon(size: Int, artwork: CGImage) throws -> Data {
  let representation = try bitmap(size: size) { context in
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
  }
  return try pngData(representation, size: size)
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
  var bigEndianValue = value.bigEndian
  withUnsafeBytes(of: &bigEndianValue) { data.append(contentsOf: $0) }
}

func makeICNSData(representations: [(type: String, data: Data)]) throws -> Data {
  var chunks = Data()
  for representation in representations {
    guard let type = representation.type.data(using: .ascii), type.count == 4 else {
      throw IconGenerationError.invalidGeneratedAsset("PickVia.icns")
    }
    chunks.append(type)
    appendBigEndian(UInt32(representation.data.count + 8), to: &chunks)
    chunks.append(representation.data)
  }

  var result = Data("icns".utf8)
  appendBigEndian(UInt32(chunks.count + 8), to: &result)
  result.append(chunks)
  return result
}

func drawMenuTemplate() throws -> Data {
  let representation = try bitmap(size: 44) { context in
    context.scaleBy(x: 2, y: 2)
    context.translateBy(x: 0, y: 22)
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: 1, y: -1)
    context.setStrokeColor(color(0x000000))
    context.setFillColor(color(0x000000))
    context.setLineCap(.round)
    context.setLineJoin(.round)

    let route = CGMutablePath()
    route.move(to: CGPoint(x: 3, y: 11))
    route.addLine(to: CGPoint(x: 8.1, y: 11))
    route.addCurve(
      to: CGPoint(x: 17.1, y: 4),
      control1: CGPoint(x: 10.1, y: 11),
      control2: CGPoint(x: 10.8, y: 7.9)
    )
    route.move(to: CGPoint(x: 8.1, y: 11))
    route.addCurve(
      to: CGPoint(x: 17.1, y: 20),
      control1: CGPoint(x: 10.1, y: 11),
      control2: CGPoint(x: 10.8, y: 16.1)
    )
    context.addPath(route)
    context.setLineWidth(2.15)
    context.strokePath()
    let arrowheads = CGMutablePath()
    arrowheads.move(to: CGPoint(x: 14.2, y: 4))
    arrowheads.addLine(to: CGPoint(x: 17.1, y: 4))
    arrowheads.addLine(to: CGPoint(x: 17.1, y: 6.9))
    arrowheads.move(to: CGPoint(x: 14.2, y: 20))
    arrowheads.addLine(to: CGPoint(x: 17.1, y: 20))
    arrowheads.addLine(to: CGPoint(x: 17.1, y: 17.1))
    context.addPath(arrowheads)
    context.strokePath()
    context.addEllipse(in: CGRect(x: 6.55, y: 9.45, width: 3.1, height: 3.1))
    context.fillPath()
  }
  return try pngData(representation, size: 44)
}

func validateApplicationIcon(at url: URL) throws {
  guard let image = NSImage(contentsOf: url) else {
    throw IconGenerationError.invalidGeneratedAsset("PickVia.icns")
  }
  let widths = Set(image.representations.map(\.pixelsWide))
  guard [16, 32, 64, 128, 256, 512, 1024].allSatisfy(widths.contains) else {
    throw IconGenerationError.invalidGeneratedAsset("PickVia.icns")
  }
}

func validateMenuTemplate(at url: URL) throws {
  let data = try Data(contentsOf: url)
  guard let bitmap = NSBitmapImageRep(data: data),
    bitmap.pixelsWide == 44,
    bitmap.pixelsHigh == 44,
    bitmap.hasAlpha
  else {
    throw IconGenerationError.invalidGeneratedAsset("PickViaMenuBarTemplate.png")
  }
}

func outputDirectory(from arguments: [String], repositoryRoot: URL) throws -> URL {
  let commandArguments = Array(arguments.dropFirst())
  if commandArguments.isEmpty {
    return repositoryRoot.appending(path: "Support/Icons", directoryHint: .isDirectory)
  }
  guard
    commandArguments.count == 2,
    commandArguments[0] == "--output-dir",
    !commandArguments[1].isEmpty,
    !commandArguments[1].hasPrefix("-")
  else {
    throw IconGenerationError.invalidArguments
  }
  return URL(fileURLWithPath: commandArguments[1], isDirectory: true)
}

func main() throws {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let outputDirectory = try outputDirectory(
    from: CommandLine.arguments,
    repositoryRoot: repositoryRoot
  )
  let applicationArtwork = try loadApplicationArtwork(repositoryRoot: repositoryRoot)
  let temporary = FileManager.default.temporaryDirectory
    .appending(path: "pickvia-icons-\(UUID().uuidString)", directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: temporary) }
  try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

  var icnsRepresentations: [(type: String, data: Data)] = []
  for representation in iconRepresentations {
    let data = try drawApplicationIcon(size: representation.pixels, artwork: applicationArtwork)
    icnsRepresentations.append((representation.icnsType, data))
  }
  let menuData = try drawMenuTemplate()
  let stagedMenu = temporary.appending(path: "PickViaMenuBarTemplate.png")
  try menuData.write(to: stagedMenu, options: .atomic)

  let stagedICNS = temporary.appending(path: "PickVia.icns")
  try makeICNSData(representations: icnsRepresentations).write(to: stagedICNS, options: .atomic)

  try validateMenuTemplate(at: stagedMenu)
  try validateApplicationIcon(at: stagedICNS)
  try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
  for (source, name) in [(stagedICNS, "PickVia.icns"), (stagedMenu, "PickViaMenuBarTemplate.png")] {
    let data = try Data(contentsOf: source)
    guard !data.isEmpty else { throw IconGenerationError.pngEncodingFailed(0) }
    try data.write(to: outputDirectory.appending(path: name), options: .atomic)
  }
}

do {
  try main()
} catch IconGenerationError.invalidArguments {
  fputs("invalidArguments\n", stderr)
  exit(64)
} catch {
  fputs("\(error)\n", stderr)
  exit(1)
}
