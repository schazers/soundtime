// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Soundtime",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Soundtime", targets: ["Soundtime"]),
    ],
    targets: [
        .executableTarget(
            name: "Soundtime",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
    ]
)
