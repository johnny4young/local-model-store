// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalModelStore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LocalModelStore", targets: ["LocalModelStore"])
    ],
    targets: [
        .target(name: "LocalModelStore"),
        .testTarget(name: "LocalModelStoreTests", dependencies: ["LocalModelStore"])
    ]
)
