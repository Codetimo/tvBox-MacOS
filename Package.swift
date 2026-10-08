// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TVBoxMacOS",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TVBoxMacOS", targets: ["TVBoxMacOS"])
    ],
    targets: [
        .executableTarget(name: "TVBoxMacOS"),
        .testTarget(name: "TVBoxMacOSTests", dependencies: ["TVBoxMacOS"])
    ]
)
