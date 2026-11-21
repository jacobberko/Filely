// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Filer",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Filer", targets: ["Filer"]), .library(name: "FilerCore", targets: ["FilerCore"])],
    targets: [
        .target(name: "FilerCore"),
        .executableTarget(name: "Filer", dependencies: ["FilerCore"]),
        .testTarget(name: "FilerCoreTests", dependencies: ["FilerCore"])
    ],
    swiftLanguageModes: [.v5]
)
