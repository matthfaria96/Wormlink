// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Wormlink",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Wormlink", targets: ["Wormlink"]),
        // Linha de comando (o build-app.sh copia para Contents/SharedSupport/bin/wormlink).
        .executable(name: "wormlink-cli", targets: ["WormlinkCLI"]),
    ],
    dependencies: [
        // Citadel e swift-nio-ssh vêm de Vendor/ com patches do Wormlink (RSA com SHA-2).
        .package(path: "Vendor/Citadel"),
        .package(path: "Vendor/swift-nio-ssh"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.99.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "WormlinkCore",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Logging", package: "swift-log"),
            ],
            linkerSettings: [.linkedFramework("NetFS")]
        ),
        .executableTarget(
            name: "Wormlink",
            dependencies: ["WormlinkCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Extensão File Provider (Wormlink Disk). O build-app.sh embala o binário num .appex.
        .executableTarget(
            name: "WormlinkDisk",
            dependencies: ["WormlinkCore"],
            swiftSettings: [.unsafeFlags(["-application-extension"]), .swiftLanguageMode(.v5)],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"]),
                .linkedFramework("FileProvider"),
            ]
        ),
        .executableTarget(
            name: "WormlinkCLI",
            dependencies: ["WormlinkCore"]
        ),
        .testTarget(
            name: "WormlinkCoreTests",
            dependencies: ["WormlinkCore"]
        ),
    ]
)
