// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PalmControl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PalmControl", targets: ["PalmControl"]),
        .executable(name: "palmctl", targets: ["palmctl"]),
    ],
    targets: [
        .target(name: "PalmControl", path: "Sources/PalmControl"),
        .executableTarget(name: "palmctl", dependencies: ["PalmControl"], path: "Sources/palmctl"),
        .testTarget(name: "PalmControlTests", dependencies: ["PalmControl"], path: "Tests"),
    ]
)
