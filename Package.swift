// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ShareMD",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .executable(name: "share-md", targets: ["ShareMDCLI"]),
        .library(name: "ShareProtocol", targets: ["ShareProtocol"]),
    ],
    targets: [
        .target(name: "ShareProtocol"),
        .executableTarget(name: "ShareMDCLI", dependencies: ["ShareProtocol"]),
        .testTarget(name: "ShareMDCLITests", dependencies: ["ShareMDCLI"]),
        .testTarget(
            name: "ShareProtocolTests",
            dependencies: ["ShareProtocol"],
            resources: [.process("Fixtures")]
        ),
    ]
)
