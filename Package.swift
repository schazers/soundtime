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
        .target(
            name: "SoundtimeAudioCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "Soundtime",
            dependencies: [
                "SoundtimeAudioCore",
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Metal"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(
            name: "SoundtimeAudioCoreTests",
            dependencies: [
                "SoundtimeAudioCore",
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
