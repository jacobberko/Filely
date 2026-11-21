// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Filely",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Filely", targets: ["Filely"]), .library(name: "FilelyCore", targets: ["FilelyCore"])],
    targets: [
        .target(name: "FilelyCore"),
        .executableTarget(name: "Filely", dependencies: ["FilelyCore"]),
        .testTarget(name: "FilelyCoreTests", dependencies: ["FilelyCore"])
    ],
    swiftLanguageModes: [.v5]
)
