// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpeakboardDemo",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SpeakboardDemo",
            path: "Sources/SpeakboardDemo",
            linkerSettings: [
                // Carbon is needed for RegisterEventHotKey (global hotkey, no Accessibility permission required).
                .linkedFramework("Carbon"),
            ]
        ),
    ]
)
