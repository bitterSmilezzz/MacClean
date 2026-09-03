// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacClean",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/nalexn/ViewInspector.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "MacClean",
            dependencies: ["ViewInspector"],
            path: "Sources/MacClean"
        ),
    ]
)
