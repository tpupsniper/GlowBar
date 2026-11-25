// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GlowBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GlowBar",
            path: "Sources/GlowBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("EventKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
