// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MenubarUsage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "menubar-usage", targets: ["MenubarUsage"])
    ],
    targets: [
        .executableTarget(
            name: "MenubarUsage",
            path: "Sources/MenubarUsage"
        )
    ]
)
