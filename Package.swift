// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "AiLiveApp",
    platforms: [.iOS(.v15)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "AiLiveApp",
            dependencies: [],
            path: "AiLiveApp"
        )
    ]
)
