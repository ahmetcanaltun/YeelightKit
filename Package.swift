// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YeelightKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "YeelightKit", targets: ["YeelightKit"])
    ],
    targets: [
        .target(
            name: "YeelightKit",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(name: "YeelightKitTests", dependencies: ["YeelightKit"])
    ]
)
