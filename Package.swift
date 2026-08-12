// swift-tools-version: 6.0

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .unsafeFlags(["-strict-concurrency=complete"])
]

let package = Package(
    name: "macshot",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "MacshotCore", targets: ["MacshotCore"]),
        .executable(name: "macshot", targets: ["macshot"])
    ],
    targets: [
        .target(
            name: "MacshotCore",
            path: "Sources/MacshotCore",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "macshot",
            dependencies: ["MacshotCore"],
            path: "Sources/macshot",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "macshotTests",
            dependencies: ["MacshotCore"],
            path: "Tests/macshotTests",
            swiftSettings: strictSwiftSettings
        )
    ]
)
