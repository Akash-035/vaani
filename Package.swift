// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GujType",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GujType", targets: ["GujType"])],
    targets: [
        .executableTarget(
            name: "GujType",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(name: "GujTypeTests", dependencies: ["GujType"])
    ]
)
