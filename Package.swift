// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipboardShelf",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ClipboardShelf", targets: ["ClipboardShelf"])],
    targets: [
        .executableTarget(name: "ClipboardShelf"),
        .testTarget(name: "ClipboardShelfTests", dependencies: ["ClipboardShelf"])
    ]
)
