// swift-tools-version: 6.2.0
import PackageDescription

let package = Package(
    name: "WendyAgentE2ETests",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "WendyAgentE2E", targets: ["WendyAgentE2E"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.4.0"),
        .package(url: "https://github.com/apple/swift-system", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "WendyAgentE2E",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/WendyAgentE2E"
        ),
        .testTarget(
            name: "WendyAgentE2ETests",
            dependencies: ["WendyAgentE2E"],
            path: "Tests/WendyAgentE2ETests"
        ),
    ]
)
