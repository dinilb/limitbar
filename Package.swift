// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LimitBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LimitBarMenuBar", targets: ["LimitBarMenuBar"]),
        .executable(name: "limitbar", targets: ["LimitBarCLI"]),
        .library(name: "LimitBarDomain", targets: ["LimitBarDomain"]),
        .library(name: "LimitBarProviders", targets: ["LimitBarProviders"])
    ],
    targets: [
        .target(name: "LimitBarDomain"),

        .target(
            name: "LimitBarProviders",
            dependencies: ["LimitBarDomain"],
            linkerSettings: [
                .linkedFramework("Security"),
                // Supplies the LAContext that keeps a background Keychain read silent.
                .linkedFramework("LocalAuthentication")
            ]
        ),

        .executableTarget(
            name: "LimitBarMenuBar",
            dependencies: ["LimitBarDomain", "LimitBarProviders"]
        ),

        .executableTarget(
            name: "LimitBarCLI",
            dependencies: ["LimitBarDomain", "LimitBarProviders"]
        ),

        // Built as a library here purely so `swift build` type-checks it.
        // scripts/build-app.sh recompiles these sources into the .appex with
        // -DWIDGET_EXTENSION, which is what turns on the @main entry point.
        .target(
            name: "LimitBarWidget",
            dependencies: ["LimitBarDomain"]
        ),

        .testTarget(
            name: "LimitBarDomainTests",
            dependencies: ["LimitBarDomain"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LimitBarProvidersTests",
            dependencies: ["LimitBarDomain", "LimitBarProviders"]
        )
    ]
)
