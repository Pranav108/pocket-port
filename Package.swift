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
        .target(
            name: "CPocketPortPairing",
            exclude: ["vendor/LICENSE"],
            cSettings: [
                .headerSearchPath("vendor/include"),
            ]
        ),
        .target(name: "PocketPortProtocol", dependencies: ["CPocketPortPairing"]),
        .executableTarget(name: "PocketPortCLI", dependencies: ["PocketPortProtocol"]),
        .testTarget(name: "PocketPortCLITests", dependencies: ["PocketPortCLI"]),
        .testTarget(
            name: "PocketPortProtocolTests",
            dependencies: ["PocketPortProtocol", "CPocketPortPairing"],
            resources: [.process("Fixtures")]
        ),
    ]
)
