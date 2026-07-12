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
    targets: [
        .target(name: "CBNKit"),
        .executableTarget(name: "cbnc", dependencies: ["CBNKit"]),
        .testTarget(name: "CBNKitTests", dependencies: ["CBNKit"]),
    ]
)
