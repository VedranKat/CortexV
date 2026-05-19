// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CortexV",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CortexV", targets: ["CortexV"])
    ],
    targets: [
        .executableTarget(
            name: "CortexV",
            path: "Sources/CortexV",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
