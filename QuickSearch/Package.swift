// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickSearch",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "QuickSearch", targets: ["QuickSearch"]),
        .library(name: "Database", targets: ["Database"]),
        .library(name: "IndexEngine", targets: ["IndexEngine"]),
    ],
    targets: [
        .executableTarget(
            name: "QuickSearch",
            dependencies: ["IndexEngine"],
            path: "Sources/QuickSearch"
        ),
        .target(
            name: "Database",
            path: "Sources/Database",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "IndexEngine",
            dependencies: ["Database"],
            path: "Sources/IndexEngine",
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
        // NOTE: Tests use Swift Testing / XCTest which require full Xcode SDK.
        // Uncomment when Xcode.app is installed:
        // .testTarget(
        //     name: "IndexEngineTests",
        //     dependencies: ["IndexEngine"],
        //     path: "Tests/IndexEngineTests"
        // ),
    ]
)
