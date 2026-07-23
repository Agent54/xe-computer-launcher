// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "macos",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "macos",
            exclude: [
                "Info.plist",
                "Entitlements.plist",
                "Resources/app.icns",
                "Resources/status-icon.png",
                "Resources/vms",
                "sandbox"
            ],
            resources: [
                .copy("Resources/Preferences.json"),
                .copy("Resources/Local State"),
                .copy("Resources/sources.json")
            ]
        )
    ]
)
