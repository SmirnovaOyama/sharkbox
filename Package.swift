// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "orbshark",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "shark",
            path: "Sources/shark",
            linkerSettings: [.linkedFramework("Virtualization")]
        )
    ]
)
