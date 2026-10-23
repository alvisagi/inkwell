// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Inkwell",
    platforms: [.macOS(.v15)],
    targets: [
        // Static Rust library + C headers, produced by scripts/build-core.sh.
        .binaryTarget(name: "TypstCoreFFI", path: "Frameworks/TypstCoreFFI.xcframework"),
        // UniFFI-generated Swift bindings.
        .target(
            name: "TypstCore",
            dependencies: ["TypstCoreFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Inkwell",
            dependencies: ["TypstCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("iconv"),
            ]
        ),
    ]
)
