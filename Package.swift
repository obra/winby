// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Winby",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Winby", targets: ["Winby"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Winby",
            dependencies: [
                "KeyboardShortcuts",
                "Sparkle"
            ],
            path: "Sources",
            linkerSettings: [
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks"]),
                .linkedFramework("SkyLight")
            ]
        )
    ]
)
