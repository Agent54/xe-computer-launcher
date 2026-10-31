// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "macos",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "macos",
            dependencies: [
                "PortHelperSupport",
                "LauncherMaintenance",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: [
                "Info.plist",
                "Entitlements.plist",
                "SmolVMEntitlements.plist",
                "WorkerdEntitlements.plist",
                "PortHelperLaunchDaemon.plist",
                "Resources/app.icns",
                "Resources/status-icon.png",
                "sandbox"
            ],
            resources: [
                .copy("Resources/Preferences.json"),
                .copy("Resources/Local State"),
                .copy("Resources/sources.json")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .target(name: "PortHelperSupport"),
        .target(name: "LauncherMaintenance"),
        .executableTarget(name: "port-helper", dependencies: ["PortHelperSupport"], path: "Sources/PortHelper"),
        .executableTarget(name: "maintenance-test-helper", dependencies: ["LauncherMaintenance"], path: "Tests/Fixtures/MaintenanceHelper"),
        .executableTarget(name: "settings-termination-test", dependencies: ["LauncherMaintenance"], path: "Tests/Fixtures/SettingsTermination"),
        .testTarget(
            name: "RuntimeTests",
            dependencies: [
                "macos", "PortHelperSupport", "LauncherMaintenance", "port-helper",
                "maintenance-test-helper", "settings-termination-test"
            ],
            path: "Tests/RuntimeTests"
        )
    ]
)
