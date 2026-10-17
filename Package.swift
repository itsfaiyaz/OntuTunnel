// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OntuTunnel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OntuTunnel",
            path: "Sources/OntuTunnel"
        )
    ]
)
