// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeCompanion",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCompanion",
            path: "Sources/ClaudeCompanion"
        ),
        .testTarget(
            name: "ClaudeCompanionTests",
            dependencies: ["ClaudeCompanion"],
            path: "Tests/ClaudeCompanionTests"
        ),
    ]
)
