// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "hbr_engine",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "hbr-engine", targets: ["hbr_engine"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        // Portable C++ matte engine shared with Android (symlinked from /core).
        .target(
            name: "HbrCore",
            path: "Sources/HbrCore"
        ),
        .target(
            name: "hbr_engine",
            dependencies: [
                "HbrCore",
                .product(name: "FlutterFramework", package: "FlutterFramework"),
            ],
            path: "Sources/hbr_engine",
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
