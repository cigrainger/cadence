// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cadence",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cadence", targets: ["Cadence"])],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [
        .target(name: "MusicCore", dependencies: ["ZIPFoundation"]),
        .executableTarget(name: "Cadence", dependencies: ["MusicCore"]),
        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore", "ZIPFoundation"]),
        .testTarget(name: "CadenceTests", dependencies: ["Cadence", "MusicCore"]),
    ],
    swiftLanguageModes: [.v5]
)
