// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Speakboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Speakboard",
            path: "Sources/Speakboard",
            linkerSettings: [
                // Carbon is needed for RegisterEventHotKey (global hotkey, no Accessibility permission required).
                .linkedFramework("Carbon"),
                .linkedFramework("Network"),
            ]
        ),
    ]
)
