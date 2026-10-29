// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeedleDesktop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NeedleDesktop", targets: ["NeedleDesktop"])],
    dependencies: [
        // Sparkle handles signed, user-consented updates from the public GitHub
        // distribution feed. The generated app bundle supplies SUFeedURL and
        // SUPublicEDKey when a release build is configured for updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "NeedleDesktop",
            dependencies: [.product(name: "Sparkle", package: "sparkle")],
            path: "Sources"
        ),
        .testTarget(
            name: "NeedleDesktopTests",
            dependencies: ["NeedleDesktop"],
            path: "Tests",
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath",
                "-Xlinker", "@loader_path/../../../../../../artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64",
                "-Xlinker", "-rpath",
                "-Xlinker", "@loader_path/../../../../../artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
            ])]
        )
    ]
)
