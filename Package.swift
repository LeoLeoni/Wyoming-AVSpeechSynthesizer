// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "wyoming-avspeech",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "wyoming-avspeech"),
    ]
)
