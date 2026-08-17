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
    dependencies: [
        // In-app updater. Binary xcframework; scripts/bundle.sh embeds it into
        // the app bundle. Pinned exactly (Package.resolved is gitignored) and
        // kept in sync with the tools download in .github/workflows/release.yml.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(
            name: "MacshotCore",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
