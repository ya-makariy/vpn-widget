// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "vpn-widget",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "VPNWidget", targets: ["VPNWidget"]),
        .executable(name: "vpnw", targets: ["vpnw"]),
        .executable(name: "vpn-tunnel", targets: ["vpn-tunnel"]),
        .library(name: "VPNWidgetCore", targets: ["VPNWidgetCore"]),
    ],
    targets: [
        .target(
            name: "VPNWidgetCore",
            linkerSettings: [
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(name: "VPNWidget", dependencies: ["VPNWidgetCore"]),
        .executableTarget(name: "vpnw", dependencies: ["VPNWidgetCore"]),
        .executableTarget(name: "vpn-tunnel", dependencies: ["VPNWidgetCore"]),
        .testTarget(name: "VPNWidgetCoreTests", dependencies: ["VPNWidgetCore"]),
    ],
    swiftLanguageModes: [.v6]
)
