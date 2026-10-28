// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GPSVPNAgent",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "GPSVPNAgent",
            path: "Sources/GPSVPNAgent"
        )
    ]
)
