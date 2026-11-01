// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ISOCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ISOCore", targets: ["ISOCore"]),
        .library(name: "ISOEngine", targets: ["ISOEngine"]),
        .executable(name: "isorec", targets: ["isorec"]),
    ],
    targets: [
        .target(name: "ISOCore"),
        // Real-time code is unsafe-pointer heavy and synchronised by hand, so it stays in Swift 5 mode.
        .target(name: "ISOEngine", dependencies: ["ISOCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "isorec", dependencies: ["ISOCore", "ISOEngine"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ISOCoreTests", dependencies: ["ISOCore"]),
        .testTarget(name: "ISOEngineTests", dependencies: ["ISOCore", "ISOEngine"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
