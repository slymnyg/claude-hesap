// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeHesap",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeHesap", path: "Sources/ClaudeHesap")
    ]
)
