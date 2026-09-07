// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "PickVia",
  defaultLocalization: "en",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "PickViaCore", targets: ["PickViaCore"]),
    .executable(name: "PickVia", targets: ["PickVia"]),
  ],
  targets: [
    .target(name: "PickViaCore", resources: [.process("Resources")]),
    .executableTarget(name: "PickVia", dependencies: ["PickViaCore"]),
    .testTarget(name: "PickViaCoreTests", dependencies: ["PickViaCore"]),
    .testTarget(name: "PickViaTests", dependencies: ["PickVia", "PickViaCore"]),
  ]
)
