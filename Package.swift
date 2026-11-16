// swift-tools-version: 6.2
import PackageDescription

// EarSax: per-app volume from the menu bar. One app module plus its tests; nothing else until something needs it.
let package = Package(
    name: "EarSax",
    platforms: [.macOS("26.0")],   // bundle-ID taps need macOS 26
    targets: [
        .executableTarget(name: "EarSax", path: "Sources/EarSax"),
        .testTarget(name: "EarSaxTests", dependencies: ["EarSax"], path: "Tests/EarSaxTests"),
    ]
)
