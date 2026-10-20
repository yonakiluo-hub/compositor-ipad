// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CompositorKit",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "CompositorKit", targets: ["CompositorKit"])],
    targets: [
        .target(name: "CompositorKit", path: "Sources", exclude: ["App"]),
        .testTarget(name: "CompositorKitTests", dependencies: ["CompositorKit"], path: "Tests")
    ]
)
