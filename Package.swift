// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingBRDAgent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MeetingBRDAgent",
            path: "Sources/MeetingBRDAgent"
        )
    ]
)
