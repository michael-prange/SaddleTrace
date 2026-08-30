// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MeshKit",
    platforms: [.iOS(.v17), .macOS(.v26)],
    products: [
        .library(name: "MeshKit", targets: ["MeshKit"]),
    ],
    targets: [
        .target(name: "MeshKit"),
        .testTarget(name: "MeshKitTests", dependencies: ["MeshKit"]),
    ]
)
