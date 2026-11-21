// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PocketPort",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .executable(name: "pocket-port", targets: ["PocketPortCLI"]),
        .library(name: "PocketPortProtocol", targets: ["PocketPortProtocol"]),
    ],
    targets: [
        .target(name: "PocketPortProtocol"),
        .executableTarget(name: "PocketPortCLI", dependencies: ["PocketPortProtocol"]),
        .testTarget(name: "PocketPortCLITests", dependencies: ["PocketPortCLI"]),
        .testTarget(
            name: "PocketPortProtocolTests",
            dependencies: ["PocketPortProtocol"],
            resources: [.process("Fixtures")]
        ),
    ]
)
