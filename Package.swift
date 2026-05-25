// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "status-bar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "StatusBarCore"),
        .executableTarget(
            name: "track",
            dependencies: ["StatusBarCore"]
        ),
        .executableTarget(
            name: "StatusBarApp",
            dependencies: ["StatusBarCore"]
        ),
    ]
)
