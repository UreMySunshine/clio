// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clio",
            path: "Sources/Clio"
        )
    ]
)
