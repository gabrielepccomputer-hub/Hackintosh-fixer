// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HackintoshFixer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HackintoshFixer", targets: ["HackintoshFixer"])
    ],
    targets: [
        .executableTarget(name: "HackintoshFixer")
    ]
)
