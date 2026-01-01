// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Winby",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Winby", targets: ["Winby"]),
        .executable(name: "SpaceSwitchTest", targets: ["SpaceSwitchTest"]),
        .executable(name: "WindowFilterTest", targets: ["WindowFilterTest"])
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
            path: "Sources/Winby",
            linkerSettings: [
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks"]),
                .linkedFramework("SkyLight")
            ]
        ),
        .executableTarget(
            name: "SpaceSwitchTest",
            path: "Sources/SpaceSwitchTest",
            linkerSettings: [
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks"]),
                .linkedFramework("SkyLight")
            ]
        ),
        .executableTarget(
            name: "WindowFilterTest",
            path: "Sources/WindowFilterTest",
            linkerSettings: [
                .unsafeFlags(["-F", "/System/Library/PrivateFrameworks"]),
                .linkedFramework("SkyLight")
            ]
        )
    ]
)
