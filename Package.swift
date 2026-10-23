// swift-tools-version:6.0
import PackageDescription

let libpqLib = "/opt/homebrew/opt/libpq/lib"

let package = Package(
    name: "TableExtra",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TableExtra", targets: ["TableExtra"]),
        .executable(name: "tableextra-mcp", targets: ["tableextra-mcp"]),
        .library(name: "MTPCore", targets: ["MTPCore"]),
    ],
    targets: [
        .systemLibrary(name: "CLibPQ", path: "Sources/CLibPQ"),
        .target(
            name: "MTPCore",
            dependencies: ["CLibPQ"],
            path: "Sources/MTPCore",
            linkerSettings: [
                .unsafeFlags(["-L\(libpqLib)"]),
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
            ]
        ),
        .target(name: "MTPUIKit", dependencies: ["MTPCore"], path: "Sources/MTPUIKit"),
        .target(name: "FeatureInsights", dependencies: ["MTPCore", "MTPUIKit"], path: "Sources/FeatureInsights"),
        .target(name: "FeatureSchemaTools", dependencies: ["MTPCore", "MTPUIKit"], path: "Sources/FeatureSchemaTools"),
        .target(name: "FeatureDataTransfer", dependencies: ["MTPCore", "MTPUIKit"], path: "Sources/FeatureDataTransfer"),
        .target(name: "FeatureAI", dependencies: ["MTPCore", "MTPUIKit"], path: "Sources/FeatureAI"),
        .executableTarget(
            name: "TableExtra",
            dependencies: ["MTPCore", "MTPUIKit", "FeatureInsights", "FeatureSchemaTools", "FeatureDataTransfer", "FeatureAI"],
            path: "Sources/TableExtra"
        ),
        .executableTarget(name: "tableextra-mcp", dependencies: ["MTPCore"], path: "Sources/tableextra-mcp"),
        .testTarget(name: "MTPCoreTests", dependencies: ["MTPCore"], path: "Tests/MTPCoreTests"),
        .testTarget(name: "FeatureInsightsTests", dependencies: ["FeatureInsights"], path: "Tests/FeatureInsightsTests"),
        .testTarget(name: "FeatureSchemaToolsTests", dependencies: ["FeatureSchemaTools"], path: "Tests/FeatureSchemaToolsTests"),
        .testTarget(name: "FeatureDataTransferTests", dependencies: ["FeatureDataTransfer"], path: "Tests/FeatureDataTransferTests"),
        .testTarget(name: "FeatureAITests", dependencies: ["FeatureAI"], path: "Tests/FeatureAITests"),
        .testTarget(name: "MCPServerTests", dependencies: ["tableextra-mcp", "MTPCore"], path: "Tests/MCPServerTests", exclude: ["e2e.sh"]),
    ],
    swiftLanguageModes: [.v5]
)
