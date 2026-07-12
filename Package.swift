// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ColorByNumbers",
    platforms: [
        .macOS(.v13),   // cbnc CLI + tuning workflow on the dev Mac
        .iOS(.v17),     // iPad app floor (iPad Air 4 reference device)
    ],
    products: [
        .library(name: "CBNKit", targets: ["CBNKit"]),
        .executable(name: "cbnc", targets: ["cbnc"]),
    ],
    dependencies: [
        // CLI-only dependency; CBNKit itself stays dependency-free.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CBNKit",
            resources: [
                // presets.json: the single source of truth for tuning
                // presets, consumed by both cbnc and the iPad app.
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "cbnc",
            dependencies: [
                "CBNKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "CBNKitTests", dependencies: ["CBNKit"]),
    ]
)
