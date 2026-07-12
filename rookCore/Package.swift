// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "rookCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "rookCore", targets: ["rookCore"]),
        .executable(name: "rookctl", targets: ["rookctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
    ],
    targets: [
        .target(name: "rookCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .testTarget(name: "rookCoreTests", dependencies: ["rookCore"]),
        .target(
            name: "rookctlKit",
            dependencies: [
                "rookCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "rookctl", dependencies: ["rookctlKit"]),
        .testTarget(name: "rookctlKitTests", dependencies: ["rookctlKit"]),
    ],
    swiftLanguageModes: [.v6]
)
