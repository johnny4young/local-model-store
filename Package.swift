// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalModelStore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LocalModelStore", targets: ["LocalModelStore"])
    ],
    targets: [
        .target(name: "LocalModelStore"),
        .executableTarget(name: "store-test-client", dependencies: ["LocalModelStore"], path: "Tests/StoreTestClient"),
        .testTarget(name: "LocalModelStoreTests", dependencies: ["LocalModelStore", "store-test-client"])
    ]
)
