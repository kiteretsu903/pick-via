// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PickVia",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "PickViaCore", targets: ["PickViaCore"]),
    ],
    targets: [
        .target(name: "PickViaCore"),
        .testTarget(name: "PickViaCoreTests", dependencies: ["PickViaCore"]),
    ]
)
