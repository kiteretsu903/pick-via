#!/usr/bin/env swift
import AppKit
import Foundation

enum IconGenerationError: Error {
  case bitmapAllocationFailed(Int)
  case pngEncodingFailed(Int)
  case iconutilFailed(Int32)
  case invalidArguments
}

struct IconRepresentation {
  let pixels: Int
  let filename: String
}

let iconRepresentations = [
  IconRepresentation(pixels: 16, filename: "icon_16x16.png"),
  IconRepresentation(pixels: 32, filename: "icon_16x16@2x.png"),
  IconRepresentation(pixels: 32, filename: "icon_32x32.png"),
  IconRepresentation(pixels: 64, filename: "icon_32x32@2x.png"),
  IconRepresentation(pixels: 128, filename: "icon_128x128.png"),
  IconRepresentation(pixels: 256, filename: "icon_128x128@2x.png"),
  IconRepresentation(pixels: 256, filename: "icon_256x256.png"),
  IconRepresentation(pixels: 512, filename: "icon_256x256@2x.png"),
  IconRepresentation(pixels: 512, filename: "icon_512x512.png"),
  IconRepresentation(pixels: 1024, filename: "icon_512x512@2x.png"),
]

func color(_ hexadecimal: UInt32, alpha: CGFloat = 1) -> CGColor {
  CGColor(
    red: CGFloat((hexadecimal >> 16) & 0xff) / 255,
    green: CGFloat((hexadecimal >> 8) & 0xff) / 255,
    blue: CGFloat(hexadecimal & 0xff) / 255,
    alpha: alpha
  )
}

func bitmap(size: Int, drawing: (CGContext) -> Void) throws -> NSBitmapImageRep {
  guard let representation = NSBitmapImageRep(
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
  ), let context = NSGraphicsContext(bitmapImageRep: representation)?.cgContext else {
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

func drawApplicationIcon(size: Int) throws -> Data {
  let representation = try bitmap(size: size) { context in
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)

    let squircle = CGPath(
      roundedRect: CGRect(x: 35.84, y: 35.84, width: 952.32, height: 952.32),
      cornerWidth: 225.28,
      cornerHeight: 225.28,
      transform: nil
    )
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let background = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [color(0x8177F2), color(0x545DD3), color(0x30387F)] as CFArray,
      locations: [0, 0.48, 1]
    )!
    context.drawLinearGradient(
      background,
      start: CGPoint(x: 164, y: 52),
      end: CGPoint(x: 860, y: 982),
      options: []
    )
    let highlight = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [color(0xffffff, alpha: 0.26), color(0xffffff, alpha: 0)] as CFArray,
      locations: [0, 1]
    )!
    context.drawRadialGradient(
      highlight,
      startCenter: CGPoint(x: 348, y: 246),
      startRadius: 0,
      endCenter: CGPoint(x: 348, y: 246),
      endRadius: 680,
      options: []
    )
    context.restoreGState()

    context.addPath(squircle)
    context.setStrokeColor(color(0xffffff, alpha: 0.18))
    context.setLineWidth(10.24)
    context.strokePath()

    let small = size <= 48
    context.addEllipse(in: CGRect(x: 204.8, y: 204.8, width: 614.4, height: 614.4))
    context.setFillColor(color(0xffffff, alpha: 0.09))
    context.setStrokeColor(color(0xffffff, alpha: 0.34))
    context.setLineWidth(small ? 30.72 : 25.6)
    context.drawPath(using: .fillStroke)

    let route = CGMutablePath()
    route.move(to: CGPoint(x: 512, y: 773.12))
    route.addLine(to: CGPoint(x: 512, y: 573.44))
    route.addLine(to: CGPoint(x: 337.92, y: 373.76))
    route.move(to: CGPoint(x: 512, y: 573.44))
    route.addLine(to: CGPoint(x: 686.08, y: 373.76))
    context.addPath(route)
    context.setStrokeColor(color(0xffffff))
    context.setLineWidth(small ? 87.04 : 76.8)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    let endpointRadius: CGFloat = small ? 66.56 : 61.44
    for point in [
      CGPoint(x: 337.92, y: 373.76),
      CGPoint(x: 686.08, y: 373.76),
      CGPoint(x: 512, y: 773.12),
    ] {
      context.addEllipse(in: CGRect(
        x: point.x - endpointRadius,
        y: point.y - endpointRadius,
        width: endpointRadius * 2,
        height: endpointRadius * 2
      ))
      context.setFillColor(color(0xffffff))
      context.fillPath()
    }
    let decisionRadius: CGFloat = small ? 51.2 : 46.08
    context.addEllipse(in: CGRect(
      x: 512 - decisionRadius,
      y: 573.44 - decisionRadius,
      width: decisionRadius * 2,
      height: decisionRadius * 2
    ))
    context.setFillColor(color(0xD4D7FF))
    context.fillPath()
  }
  return try pngData(representation, size: size)
}

func drawMenuTemplate() throws -> Data {
  let representation = try bitmap(size: 44) { context in
    context.scaleBy(x: 2, y: 2)
    context.translateBy(x: 0, y: 22)
    context.scaleBy(x: 1, y: -1)
    context.setStrokeColor(color(0x000000))
    context.setFillColor(color(0x000000))
    context.setLineCap(.round)
    context.setLineJoin(.round)

    context.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
    context.setLineWidth(1.8)
    context.strokePath()
    let route = CGMutablePath()
    route.move(to: CGPoint(x: 12, y: 19))
    route.addLine(to: CGPoint(x: 12, y: 13))
    route.addLine(to: CGPoint(x: 7.3, y: 7.5))
    route.move(to: CGPoint(x: 12, y: 13))
    route.addLine(to: CGPoint(x: 16.7, y: 7.5))
    context.addPath(route)
    context.setLineWidth(2)
    context.strokePath()
    for point in [CGPoint(x: 7.3, y: 7.5), CGPoint(x: 16.7, y: 7.5)] {
      context.addEllipse(in: CGRect(x: point.x - 1.4, y: point.y - 1.4, width: 2.8, height: 2.8))
      context.fillPath()
    }
    context.addEllipse(in: CGRect(x: 10.6, y: 17.6, width: 2.8, height: 2.8))
    context.fillPath()
    context.addEllipse(in: CGRect(x: 11, y: 12, width: 2, height: 2))
    context.fillPath()
  }
  return try pngData(representation, size: 44)
}

func argumentValue(after flag: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: flag),
    CommandLine.arguments.indices.contains(index + 1)
  else { return nil }
  return CommandLine.arguments[index + 1]
}

let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
let outputDirectory = argumentValue(after: "--output-dir").map {
  URL(fileURLWithPath: $0, isDirectory: true)
} ?? repositoryRoot.appending(path: "Support/Icons", directoryHint: .isDirectory)
let temporary = FileManager.default.temporaryDirectory
  .appending(path: "pickvia-icons-\(UUID().uuidString)", directoryHint: .isDirectory)
let iconset = temporary.appending(path: "PickVia.iconset", directoryHint: .isDirectory)
defer { try? FileManager.default.removeItem(at: temporary) }
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for representation in iconRepresentations {
  let data = try drawApplicationIcon(size: representation.pixels)
  try data.write(to: iconset.appending(path: representation.filename), options: .atomic)
}
let menuData = try drawMenuTemplate()
let stagedMenu = temporary.appending(path: "PickViaMenuBarTemplate.png")
try menuData.write(to: stagedMenu, options: .atomic)

let stagedICNS = temporary.appending(path: "PickVia.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", stagedICNS.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
  throw IconGenerationError.iconutilFailed(iconutil.terminationStatus)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for (source, name) in [(stagedICNS, "PickVia.icns"), (stagedMenu, "PickViaMenuBarTemplate.png")] {
  let data = try Data(contentsOf: source)
  guard !data.isEmpty else { throw IconGenerationError.pngEncodingFailed(0) }
  try data.write(to: outputDirectory.appending(path: name), options: .atomic)
}
