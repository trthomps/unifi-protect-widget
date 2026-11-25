// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ProtectCameras",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ProtectCameras", targets: ["ProtectCameras"]),
    ],
    targets: [
        .executableTarget(
            name: "ProtectCameras",
            path: "Sources/ProtectCameras"
        ),
    ]
)
