#!/usr/bin/env swift
import AppKit
import Foundation

let outputPath =
  CommandLine.arguments.dropFirst().first
  ?? "Support/DMG/dmg-background.png"
let outputURL = URL(fileURLWithPath: outputPath)
let size = NSSize(width: 660, height: 400)

try FileManager.default.createDirectory(
  at: outputURL.deletingLastPathComponent(),
  withIntermediateDirectories: true)

let image = NSImage(size: size)
image.lockFocus()

let bounds = NSRect(origin: .zero, size: size)
let gradient = NSGradient(colors: [
  NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.18, alpha: 1),
  NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.31, alpha: 1),
])!
gradient.draw(in: bounds, angle: -35)

let leftTarget = NSRect(x: 105, y: 108, width: 130, height: 130)
let rightTarget = NSRect(x: 425, y: 108, width: 130, height: 130)
for target in [leftTarget, rightTarget] {
  NSColor.white.withAlphaComponent(0.08).setFill()
  NSBezierPath(roundedRect: target, xRadius: 26, yRadius: 26).fill()
  NSColor.white.withAlphaComponent(0.18).setStroke()
  let border = NSBezierPath(roundedRect: target, xRadius: 26, yRadius: 26)
  border.lineWidth = 1
  border.stroke()
}

let titleStyle = NSMutableParagraphStyle()
titleStyle.alignment = .center
let titleAttributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 28, weight: .bold),
  .foregroundColor: NSColor.white,
  .paragraphStyle: titleStyle,
]
"Install PickVia".draw(
  in: NSRect(x: 0, y: 320, width: size.width, height: 38),
  withAttributes: titleAttributes)

let instructionAttributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 16, weight: .medium),
  .foregroundColor: NSColor.white.withAlphaComponent(0.78),
  .paragraphStyle: titleStyle,
]
"Drag PickVia to Applications".draw(
  in: NSRect(x: 0, y: 286, width: size.width, height: 24),
  withAttributes: instructionAttributes)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 262, y: 173))
arrow.line(to: NSPoint(x: 390, y: 173))
arrow.lineWidth = 6
arrow.lineCapStyle = .round
NSColor(calibratedRed: 0.35, green: 0.86, blue: 1, alpha: 1).setStroke()
arrow.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: NSPoint(x: 377, y: 187))
arrowHead.line(to: NSPoint(x: 393, y: 173))
arrowHead.line(to: NSPoint(x: 377, y: 159))
arrowHead.lineWidth = 6
arrowHead.lineCapStyle = .round
arrowHead.lineJoinStyle = .round
arrowHead.stroke()

let footerAttributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 12, weight: .regular),
  .foregroundColor: NSColor.white.withAlphaComponent(0.48),
  .paragraphStyle: titleStyle,
]
"macOS 14 or later  •  Apple Silicon".draw(
  in: NSRect(x: 0, y: 32, width: size.width, height: 18),
  withAttributes: footerAttributes)

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
  let bitmap = NSBitmapImageRep(data: tiffData),
  let pngData = bitmap.representation(using: .png, properties: [:])
else {
  fatalError("Could not render DMG background")
}

try pngData.write(to: outputURL)
