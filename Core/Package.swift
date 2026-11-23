// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoDropCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PhotoDropCore", targets: ["PhotoDropCore"]),
    ],
    targets: [
        .target(name: "PhotoDropCore"),
        .testTarget(name: "PhotoDropCoreTests", dependencies: ["PhotoDropCore"]),
    ]
)
