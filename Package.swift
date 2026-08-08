// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Soundtime",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "Soundtime", targets: ["Soundtime"]),
        .library(name: "SoundtimeDiagnosticsCore", targets: ["SoundtimeDiagnosticsCore"]),
        .executable(name: "SoundtimeLog", targets: ["SoundtimeLog"]),
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
        .target(
            name: "SoundtimeEditing"
        ),
        .target(name: "SoundtimeDiagnosticsCore"),
        .executableTarget(
            name: "SoundtimeLog",
            dependencies: ["SoundtimeDiagnosticsCore"]
        ),
        .executableTarget(
            name: "Soundtime",
            dependencies: [
                "SoundtimeAudioCore",
                "SoundtimeEditing",
                "SoundtimeDiagnosticsCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .process("Resources"),
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
        .testTarget(
            name: "SoundtimeEditingTests",
            dependencies: [
                "SoundtimeEditing",
            ],
            resources: [
                .process("Fixtures"),
            ]
        ),
        .testTarget(
            name: "SoundtimeDiagnosticsCoreTests",
            dependencies: ["SoundtimeDiagnosticsCore"]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
