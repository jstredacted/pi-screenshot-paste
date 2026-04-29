// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiScreenshotPaste",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PiScreenshotPaste", targets: ["PiScreenshotPaste"]),
    ],
    targets: [
        .executableTarget(
            name: "PiScreenshotPaste",
            path: "Sources/PiScreenshotPaste",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
