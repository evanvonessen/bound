// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BoundPrototypeTests", platforms: [.macOS(.v13)], targets: [
    .target(name: "Models"), .testTarget(name: "ModelTests", dependencies: ["Models"])
])
