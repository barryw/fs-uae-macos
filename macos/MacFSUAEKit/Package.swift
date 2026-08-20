// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MacFSUAEKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacFSUAEKit", targets: ["MacFSUAEKit"]),
        .executable(name: "FS-UAE Mac", targets: ["FSUAEMacApp"]),
        .executable(name: "FS-UAE Worker", targets: ["FSUAEWorker"]),
        .executable(name: "FS-UAE Stress", targets: ["FSUAEStress"]),
    ],
    targets: [
        .target(name: "CMacFSUAEEngine", linkerSettings: [.linkedLibrary("dl")]),
        .target(name: "MacFSUAEKit", dependencies: ["CMacFSUAEEngine"]),
        .executableTarget(name: "FSUAEMacApp", dependencies: ["MacFSUAEKit"]),
        .executableTarget(name: "FSUAEWorker", dependencies: ["MacFSUAEKit"]),
        .executableTarget(name: "FSUAEStress"),
        .testTarget(name: "MacFSUAEKitTests", dependencies: ["MacFSUAEKit"]),
    ],
    swiftLanguageModes: [.v6]
)
