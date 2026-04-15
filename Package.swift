// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Antler",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Antler",
            targets: ["Antler"]
        )
    ],
    targets: [
        .executableTarget(
            name: "Antler",
            path: "Sources/Antler",
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        )
    ]
)
