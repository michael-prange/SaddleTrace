// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ExportKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "ExportKit", targets: ["ExportKit"]),
    ],
    dependencies: [
        .package(path: "../MeshKit"),
    ],
    targets: [
        .target(name: "ExportKit", dependencies: ["MeshKit"]),
        .testTarget(name: "ExportKitTests", dependencies: ["ExportKit", "MeshKit"]),
    ]
)
