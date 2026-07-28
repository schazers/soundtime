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
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.2"
        ),
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
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Metal"),
                .linkedFramework("Security"),
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
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
