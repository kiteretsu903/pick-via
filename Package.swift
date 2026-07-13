// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "PickVia",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "PickViaCore", targets: ["PickViaCore"]),
    .executable(name: "PickVia", targets: ["PickVia"]),
  ],
  targets: [
    .target(name: "PickViaCore"),
    .executableTarget(name: "PickVia", dependencies: ["PickViaCore"]),
    .testTarget(name: "PickViaCoreTests", dependencies: ["PickViaCore"]),
    .testTarget(name: "PickViaTests", dependencies: ["PickVia", "PickViaCore"]),
  ]
)
