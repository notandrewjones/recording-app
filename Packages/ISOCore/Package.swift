// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ISOCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ISOCore", targets: ["ISOCore"])],
    targets: [
        .target(name: "ISOCore"),
        .testTarget(name: "ISOCoreTests", dependencies: ["ISOCore"]),
    ]
)
