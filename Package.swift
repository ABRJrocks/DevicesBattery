// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DevicesBattery",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "DevicesBattery", path: "Sources")
    ]
)
